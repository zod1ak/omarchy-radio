import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Радио: a static list of Radio Record stations (built from
// stations.md) with search, favorites and history. Playback goes through
// mpv, driven over its JSON IPC socket (Quickshell's native Socket type,
// so no extra CLI dependency like socat/ncat is needed) so volume/pause
// can be controlled live without restarting the stream.
//
// mpv's system-wide config auto-loads the mpv-mpris script for every
// instance, so this already answers to hardware media keys / MPRIS
// (Play/Pause/Stop) without any extra flag here — confirmed live: pausing
// through the shell's own media IPC toggles mpv's pause property. The
// pause/metadata observers below exist so this panel's own Pause/Resume
// label and now-playing title stay correct the instant playback changes
// that way instead of from here.
Panel {
  id: root
  moduleName: "zero.radio"
  ipcTarget: "zero.radio"

  // Everything below plays through the built-in static station list —
  // no external directory, so no API host, user agent or server
  // discovery state is needed anymore.

  readonly property int defaultVolume: setting("defaultVolume", 70)
  // mpv's own out-of-the-box default for volume-max — confirmed live, not
  // a new capability this plugin is introducing. mpv itself doesn't clamp
  // set_property volume to any ceiling (confirmed live: it echoes back
  // whatever's set, past 130 or even a raised volume-max), so this plugin
  // enforces the bound client-side, same as every other externally- or
  // user-influenced number in this file.
  readonly property int volumeCeiling: 130
  // Shared by toggleDeepBass() and ipcSocket's reconnect handler — mpv's
  // `af remove` matches by exact filter string, so the two call sites
  // must always agree on this value; naming it once rules out drift.
  readonly property string deepBassFilter: "lavfi=[bass=g=10]"

  // IDs for mpv's observe_property, referenced in both handleMpvMessage and
  // the IPC connect handler — kept as named constants so a future observed
  // property can't silently collide with one of these.
  readonly property int metadataObserveId: 1
  readonly property int pauseObserveId: 2
  readonly property int pausedForCacheObserveId: 3
  readonly property int cacheBufferingStateObserveId: 4

  // The full station directory, straight from stations.md (Radio Record).
  // id is a stable slug (used as the favorites/history key), desc is the
  // station's own tagline shown as the list row caption, url is the
  // 96 kbps AAC stream, homepage is the station's page on radiorecord.ru.
  readonly property var staticStations: [
    { id: 'record', name: 'Record', desc: 'Танцевальный мейнстрим', url: 'https://radiorecord.hostingradio.ru/rr_main96.aacp', homepage: 'https://radiorecord.ru/station/record' },
    { id: 'rus', name: 'Russian Mix', desc: 'Русские хиты в танцевальной обработке: Zivert, Niletto, Rasa', url: 'https://radiorecord.hostingradio.ru/rus96.aacp', homepage: 'https://radiorecord.ru/station/rus' },
    { id: 'khity-vsekh-vremen', name: 'Хиты всех времен', desc: 'Танцевальные боевики 3 десятилетий', url: 'https://radiorecord.hostingradio.ru/alltimers96.aacp', homepage: 'https://radiorecord.ru/station/khity-vsekh-vremen' },
    { id: 'sd90', name: 'Супердискотека 90-х', desc: 'Танцевальные боевики нашей юности Руки Вверх, 2 Unlimited, Masterboy', url: 'https://radiorecord.hostingradio.ru/sd9096.aacp', homepage: 'https://radiorecord.ru/station/sd90' },
    { id: 'russianhits', name: 'Russian Hits', desc: 'Русский танцевальный поп: Клава Кока, Niletto, Тима Белорусских', url: 'https://radiorecord.hostingradio.ru/russianhits96.aacp', homepage: 'https://radiorecord.ru/station/russianhits' },
    { id: 'pump', name: 'Колбасный Цех', desc: 'Саунд золотой эпохи рейвов: DJ Aligator, Klubbheads, Club Caviar', url: 'https://radiorecord.hostingradio.ru/pump96.aacp', homepage: 'https://radiorecord.ru/station/pump' },
    { id: 'live-dj-sets', name: 'Festivals', desc: 'Лучшие живые сеты от звезд электронной сцены', url: 'https://radiorecord.hostingradio.ru/livedjsets96.aacp', homepage: 'https://radiorecord.ru/station/live-dj-sets' },
    { id: 'deep', name: 'Deep', desc: 'Глубокое house-звучание', url: 'https://radiorecord.hostingradio.ru/deep96.aacp', homepage: 'https://radiorecord.ru/station/deep' },
    { id: 'chil', name: 'Chill-Out', desc: 'Расслабляющий вайб', url: 'https://radiorecord.hostingradio.ru/chil96.aacp', homepage: 'https://radiorecord.ru/station/chil' },
    { id: 'skazki', name: 'Сказки MC V', desc: 'Волшебные истории от старого сказочника', url: 'https://radiorecord.hostingradio.ru/skazki96.aacp', homepage: 'https://radiorecord.ru/station/skazki' },
    { id: 'nashashlyki', name: 'На шашлыки!', desc: 'Русское. Летнее. Танцевальное.', url: 'https://radiorecord.hostingradio.ru/nashashlyki96.aacp', homepage: 'https://radiorecord.ru/station/nashashlyki' },
    { id: 'mix', name: 'Megamix', desc: 'Mash-up из главных хитов Рекорда со скоростью 5 треков в минуту!', url: 'https://radiorecord.hostingradio.ru/mix96.aacp', homepage: 'https://radiorecord.ru/station/mix' },
    { id: 'rock', name: 'Rock', desc: 'Первоапрельский спецпроект: от Цоя до Metallica', url: 'https://radiorecord.hostingradio.ru/rock96.aacp', homepage: 'https://radiorecord.ru/station/rock' },
    { id: 'rmx', name: 'Remix', desc: 'Иностранные хиты в танцевальной обработке: Black Eyed Peas, Ariana Grande, Ed Sheeran', url: 'https://radiorecord.hostingradio.ru/rmx96.aacp', homepage: 'https://radiorecord.ru/station/rmx' },
    { id: 'gop', name: 'Гоп FM', desc: 'Первоапрельский спецпроект. Памп и лоходенс', url: 'https://radiorecord.hostingradio.ru/gop96.aacp', homepage: 'https://radiorecord.ru/station/gop' },
    { id: 'bighits', name: 'Big Hits', desc: 'Зарубежные танцевальные хиты: Dua Lipa, Ava Max, Sia', url: 'https://radiorecord.hostingradio.ru/bighits96.aacp', homepage: 'https://radiorecord.ru/station/bighits' },
    { id: 'chillhouse', name: 'Chill House', desc: 'Легкий, мелодичный вайб', url: 'https://radiorecord.hostingradio.ru/chillhouse96.aacp', homepage: 'https://radiorecord.ru/station/chillhouse' },
    { id: 'record00', name: 'Рекорд 00-х', desc: 'Хиты танцполов нулевых: ATB, Benassi, Klubbheads и другие', url: 'https://radiorecord.hostingradio.ru/200096.aacp', homepage: 'https://radiorecord.ru/station/record00' },
    { id: 'melodic', name: 'Melodic Techno', desc: 'Мелодичное техно в стиле Anyma, Argy и CamelPhat', url: 'https://radiorecord.hostingradio.ru/melodic96.aacp', homepage: 'https://radiorecord.ru/station/melodic' },
    { id: '1980', name: 'Record 80-х', desc: 'Ритмы советской и зарубежной эстрады. C. C. Catch, Modern Talking, В. Леонтьев и Ласковый Май', url: 'https://radiorecord.hostingradio.ru/198096.aacp', homepage: 'https://radiorecord.ru/station/1980' },
    { id: 'naft', name: 'Нафталин FM', desc: 'Первоапрельский спецпроект: Советская эстрада', url: 'https://radiorecord.hostingradio.ru/naft96.aacp', homepage: 'https://radiorecord.ru/station/naft' },
    { id: 'mf', name: 'Маятник Фуко', desc: 'Новая школа русского рэпа без цензуры: Morgenshtern, Markul, Obladaet & co. [18+]', url: 'https://radiorecord.hostingradio.ru/mf96.aacp', homepage: 'https://radiorecord.ru/station/mf' },
    { id: 'summer-dance', name: 'Summer Dance', desc: 'Летние танцевальные хиты 24/7', url: 'https://radiorecord.hostingradio.ru/summerparty96.aacp', homepage: 'https://radiorecord.ru/station/summer-dance' },
    { id: 'tm', name: 'Trancemission', desc: 'Лучшее из транс-музыки: Armin, Above & Beyond, Christina Novelli', url: 'https://radiorecord.hostingradio.ru/tm96.aacp', homepage: 'https://radiorecord.ru/station/tm' },
    { id: 'russiangold', name: 'Russian Gold', desc: 'Российские хиты в ремиксах', url: 'https://radiorecord.hostingradio.ru/russiangold96.aacp', homepage: 'https://radiorecord.ru/station/russiangold' },
    { id: 'beach', name: 'Beach Party', desc: 'Жаркий саунд пляжной вечеринки', url: 'https://radiorecord.hostingradio.ru/beach96.aacp', homepage: 'https://radiorecord.ru/station/beach' },
    { id: 'ps', name: 'Pirate Station', desc: 'Лучшее из drum & bass: Pendulum, Chase & Status, Camo & Krooked', url: 'https://radiorecord.hostingradio.ru/ps96.aacp', homepage: 'https://radiorecord.ru/station/ps' },
    { id: 'mashup', name: 'Mashup', desc: 'Dance-кроссоверы русских и зарубежных хитов', url: 'https://radiorecord.hostingradio.ru/mashup96.aacp', homepage: 'https://radiorecord.ru/station/mashup' },
    { id: 'ibiza', name: 'Innocence', desc: 'Techno, Minimal, Deep. Саунд как у Solomun, Boris Brejcha и Nina Kravitz', url: 'https://radiorecord.hostingradio.ru/ibiza96.aacp', homepage: 'https://radiorecord.ru/station/ibiza' },
    { id: 'mdl', name: 'Медляк FM', desc: 'Первоапрельский спецпроект', url: 'https://radiorecord.hostingradio.ru/mdl96.aacp', homepage: 'https://radiorecord.ru/station/mdl' },
    { id: 'party-24-7', name: 'Party 24/7', desc: 'Вечеринка с танцевальными хитами', url: 'https://radiorecord.hostingradio.ru/party96.aacp', homepage: 'https://radiorecord.ru/station/party-24-7' },
    { id: 'phonk', name: 'Phonk', desc: 'Атмосфера дрифта и уличных гонок', url: 'https://radiorecord.hostingradio.ru/phonk96.aacp', homepage: 'https://radiorecord.ru/station/phonk' },
    { id: 'gold', name: 'Record Gold', desc: 'Хиты Рекорда эпохи Avicii и Swedish House Mafia', url: 'https://radiorecord.hostingradio.ru/gold96.aacp', homepage: 'https://radiorecord.ru/station/gold' },
    { id: 'rv19', name: 'Руки Вверх!', desc: '24 часа в сутки - только песни Руки Вверх!', url: 'https://radiorecord.hostingradio.ru/rv96.aacp', homepage: 'https://radiorecord.ru/station/rv19' },
    { id: 'hype', name: 'На Хайпе', desc: 'Топ российского стриминга', url: 'https://radiorecord.hostingradio.ru/hype96.aacp', homepage: 'https://radiorecord.ru/station/hype' },
    { id: 'rap', name: 'Rap Hits', desc: 'Рэп новой волны из России и из-за рубежа', url: 'https://radiorecord.hostingradio.ru/rap96.aacp', homepage: 'https://radiorecord.ru/station/rap' },
    { id: 'rapclassics', name: 'Rap Classics', desc: 'Хип-хоп золотого периода: 2Pac, Cypress Hill, Notorius BIG, ONYX', url: 'https://radiorecord.hostingradio.ru/rapclassics96.aacp', homepage: 'https://radiorecord.ru/station/rapclassics' },
    { id: 'trancehits', name: 'Trance Classics', desc: 'Главные хиты trance-музыки: Above&Beyond, Armin van Buuren, Ferry Corsten', url: 'https://radiorecord.hostingradio.ru/trancehits96.aacp', homepage: 'https://radiorecord.ru/station/trancehits' },
    { id: 'drumhits', name: 'D\'n\'B Classics', desc: 'Золотые хиты drum\'n\'bass Aphrodite, Pendulum, Sub Focus', url: 'https://radiorecord.hostingradio.ru/drumhits96.aacp', homepage: 'https://radiorecord.ru/station/drumhits' },
    { id: 'armin', name: 'Armin van Buuren', desc: 'Лучшие треки, ремиксы и коллабы', url: 'https://radiorecord.hostingradio.ru/armin96.aacp', homepage: 'https://radiorecord.ru/station/armin' },
    { id: 'summerlounge', name: 'Summer Lounge', desc: 'Летний чил в стиле Cafe del Mar', url: 'https://radiorecord.hostingradio.ru/summerlounge96.aacp', homepage: 'https://radiorecord.ru/station/summerlounge' },
    { id: 'organic', name: 'Organic', desc: 'Легкий грув. В стиле Tim Green и Sebastien Leger', url: 'https://radiorecord.hostingradio.ru/organic96.aacp', homepage: 'https://radiorecord.ru/station/organic' },
    { id: 'ultra', name: 'Ultra Music Festival', desc: 'Live-сеты с одного из лучших электронных фестивалей мира', url: 'https://radiorecord.hostingradio.ru/ultra96.aacp', homepage: 'https://radiorecord.ru/station/ultra' },
    { id: 'vip', name: 'VIP House', desc: 'Изысканный саунд закрытых вечеринок', url: 'https://radiorecord.hostingradio.ru/vip96.aacp', homepage: 'https://radiorecord.ru/station/vip' },
    { id: 'brks', name: 'Breaks', desc: 'Лучшее из breakbeat, nu breaks и jungle', url: 'https://radiorecord.hostingradio.ru/brks96.aacp', homepage: 'https://radiorecord.ru/station/brks' },
    { id: 'liquidfunk', name: 'Liquid Funk', desc: 'Атмосферный drum\'n\'bass', url: 'https://radiorecord.hostingradio.ru/liquidfunk96.aacp', homepage: 'https://radiorecord.ru/station/liquidfunk' },
    { id: 'workout', name: 'Workout', desc: 'Бит для спортивного тонуса', url: 'https://radiorecord.hostingradio.ru/workout96.aacp', homepage: 'https://radiorecord.ru/station/workout' },
    { id: 'club', name: 'EDM', desc: 'Музыка стадионов.', url: 'https://radiorecord.hostingradio.ru/club96.aacp', homepage: 'https://radiorecord.ru/station/club' },
    { id: 'jackin', name: 'Bass House', desc: 'Современный house с характерным басом: Malaa, Volac, Valentino Khan', url: 'https://radiorecord.hostingradio.ru/jackin96.aacp', homepage: 'https://radiorecord.ru/station/jackin' },
    { id: 'goa', name: 'GOA/PSY', desc: 'Психоделический и Goa-trance', url: 'https://radiorecord.hostingradio.ru/goa96.aacp', homepage: 'https://radiorecord.ru/station/goa' },
    { id: '2010', name: '10\'s Dance', desc: 'Танцевальные хиты десятых', url: 'https://radiorecord.hostingradio.ru/201096.aacp', homepage: 'https://radiorecord.ru/station/2010' },
    { id: 'trancehouse', name: 'Trancehouse', desc: 'Trancehouse - сочетание трансовой мелодики и хаусового бита.', url: 'https://radiorecord.hostingradio.ru/trancehouse96.aacp', homepage: 'https://radiorecord.ru/station/trancehouse' },
    { id: 'yo', name: 'Black Rap', desc: 'Рэп на английском', url: 'https://radiorecord.hostingradio.ru/yo96.aacp', homepage: 'https://radiorecord.ru/station/yo' },
    { id: 'techno', name: 'Techno', desc: 'Техно для тех, кто любит пожёстче', url: 'https://radiorecord.hostingradio.ru/techno96.aacp', homepage: 'https://radiorecord.ru/station/techno' },
    { id: 'trop', name: 'Tropical', desc: 'Жаркий и солнечный house', url: 'https://radiorecord.hostingradio.ru/trop96.aacp', homepage: 'https://radiorecord.ru/station/trop' },
    { id: 'lofi', name: 'Lo-Fi', desc: 'Ламповый бит и треск винила. В стиле Nujabes и J Dilla', url: 'https://radiorecord.hostingradio.ru/lofi96.aacp', homepage: 'https://radiorecord.ru/station/lofi' },
    { id: 'techouse', name: 'Tech House', desc: 'На стыке хауса и техно. В стиле Fisher и Dont Blink', url: 'https://radiorecord.hostingradio.ru/techouse96.aacp', homepage: 'https://radiorecord.ru/station/techouse' },
    { id: 'trap', name: 'Trap', desc: 'Главные Trap-хиты: Yellow Claw, Apashe, DJ Snake', url: 'https://radiorecord.hostingradio.ru/trap96.aacp', homepage: 'https://radiorecord.ru/station/trap' },
    { id: 'technopop', name: 'Technopop', desc: 'Технопоп эпохи 90-х: E-Type, Masterboy, Culture Beat', url: 'https://radiorecord.hostingradio.ru/technopop96.aacp', homepage: 'https://radiorecord.ru/station/technopop' },
    { id: '1970', name: '70\'s Dance', desc: 'Легендарный грув. Abba, Boney M, Bee Gees', url: 'https://radiorecord.hostingradio.ru/197096.aacp', homepage: 'https://radiorecord.ru/station/1970' },
    { id: 'dream', name: 'Dream Dance', desc: 'Мелодичный trance 90х-00х: Robert Miles, ATB, Blank&Jones', url: 'https://radiorecord.hostingradio.ru/dream96.aacp', homepage: 'https://radiorecord.ru/station/dream' },
    { id: 'neurofunk', name: 'Neurofunk', desc: 'Технологичный и стремительный бит: Black Sun Empire, Dimension, Camo & Krooked', url: 'https://radiorecord.hostingradio.ru/neurofunk96.aacp', homepage: 'https://radiorecord.ru/station/neurofunk' },
    { id: 'ambient', name: 'Ambient', desc: 'Атмосферный саунд', url: 'https://radiorecord.hostingradio.ru/ambient96.aacp', homepage: 'https://radiorecord.ru/station/ambient' },
    { id: 'recordclassix', name: 'Record Classix', desc: 'Золотые танцевальные хиты Рекорда | hosted by MC Жан', url: 'https://radiorecord.hostingradio.ru/classix96.aacp', homepage: 'https://radiorecord.ru/station/recordclassix' },
    { id: 'recordclubshow', name: 'Record Club Show', desc: 'Радиошоу об актуальной клубной музыке | hosted by Tim Vox', url: 'https://radiorecord.hostingradio.ru/clubshow96.aacp', homepage: 'https://radiorecord.ru/station/recordclubshow' },
    { id: 'eurodance', name: 'Eurodance', desc: 'Дискотечные бэнгеры 90-х: Culture Beat, Haddaway, La Bouche', url: 'https://radiorecord.hostingradio.ru/eurodance96.aacp', homepage: 'https://radiorecord.ru/station/eurodance' },
    { id: 'lo-fi-house', name: 'Lo-Fi House', desc: 'Ламповый бит в стиле DJ Seinfeld & Bruce Trail.', url: 'https://radiorecord.hostingradio.ru/lofihouse96.aacp', homepage: 'https://radiorecord.ru/station/lo-fi-house' },
    { id: 'househits', name: 'House Hits', desc: 'Свежие house-новинки', url: 'https://radiorecord.hostingradio.ru/househits96.aacp', homepage: 'https://radiorecord.ru/station/househits' },
    { id: 'uplift', name: 'Uplifting', desc: 'Атмосферный и космический trance', url: 'https://radiorecord.hostingradio.ru/uplift96.aacp', homepage: 'https://radiorecord.ru/station/uplift' },
    { id: 'feel', name: 'Feel', desc: 'Главное trance-радиошоу России от DJ Feel', url: 'https://radiorecord.hostingradio.ru/feel96.aacp', homepage: 'https://radiorecord.ru/station/feel' },
    { id: 'tiesto', name: 'Tiesto', desc: 'Лучшие треки, ремиксы и коллабы', url: 'https://radiorecord.hostingradio.ru/tiesto96.aacp', homepage: 'https://radiorecord.ru/station/tiesto' },
    { id: 'a-state-of-trance', name: 'A State of Trance', desc: 'Легендарное радиошоу Армина ван Бюрена', url: 'https://radiorecord.hostingradio.ru/asot96.aacp', homepage: 'https://radiorecord.ru/station/a-state-of-trance' },
    { id: 'deti', name: 'Веснушка FM', desc: 'Первоапрельский спецпроект: песни детства', url: 'https://radiorecord.hostingradio.ru/deti96.aacp', homepage: 'https://radiorecord.ru/station/deti' },
    { id: 'symph', name: 'Симфония FM', desc: 'Первоапрельский спецпроект: Моцарт, Бетховен, Чайковский & co.', url: 'https://radiorecord.hostingradio.ru/symph96.aacp', homepage: 'https://radiorecord.ru/station/symph' },
    { id: 'mini', name: 'Minimal/Tech', desc: 'Саунд изысканных и дорогих party', url: 'https://radiorecord.hostingradio.ru/mini96.aacp', homepage: 'https://radiorecord.ru/station/mini' },
    { id: 'top-100-edm', name: 'TOP 100 EDM', desc: 'Актуальный топ электронной музыки', url: 'https://radiorecord.hostingradio.ru/top100edm96.aacp', homepage: 'https://radiorecord.ru/station/top-100-edm' },
    { id: 'dream-pop', name: 'Dream Pop', desc: 'Лёгкий вайб для отдыха и хорошего настроения', url: 'https://radiorecord.hostingradio.ru/dreampop96.aacp', homepage: 'https://radiorecord.ru/station/dream-pop' },
    { id: 'houseclss', name: 'House Classics', desc: 'Золотой фонд мелодичных house-хитов', url: 'https://radiorecord.hostingradio.ru/houseclss96.aacp', homepage: 'https://radiorecord.ru/station/houseclss' },
    { id: 'guetta', name: 'David Guetta', desc: 'Лучшие треки, ремиксы и коллабы', url: 'https://radiorecord.hostingradio.ru/guetta96.aacp', homepage: 'https://radiorecord.ru/station/guetta' },
    { id: 'tsvetkov', name: 'DJ Цветкоff', desc: 'Радиошоу ди-джея Цветкова', url: 'https://radiorecord.hostingradio.ru/tsvetkov96.aacp', homepage: 'https://radiorecord.ru/station/tsvetkov' },
    { id: 'discofunk', name: 'Disco/Funk', desc: 'Disco-саунд нового тысячелетия', url: 'https://radiorecord.hostingradio.ru/discofunk96.aacp', homepage: 'https://radiorecord.ru/station/discofunk' },
    { id: 'hbass', name: 'Hard Bass', desc: 'Расколбас родившийся в Петербурге.', url: 'https://radiorecord.hostingradio.ru/hbass96.aacp', homepage: 'https://radiorecord.ru/station/hbass' },
    { id: 'afro', name: 'Afro House', desc: 'Этно-ритмы на стыке Kwaito & soulful house.', url: 'https://radiorecord.hostingradio.ru/afro96.aacp', homepage: 'https://radiorecord.ru/station/afro' },
    { id: 'rave', name: 'Rave FM', desc: 'Первоапрельский спецпроект', url: 'https://radiorecord.hostingradio.ru/rave96.aacp', homepage: 'https://radiorecord.ru/station/rave' },
    { id: 'nu-dance', name: 'Nu Dance', desc: 'Дэнс на скорости 150 bpm в стиле Oliver Tree & Hardwell.', url: 'https://radiorecord.hostingradio.ru/nudance96.aacp', homepage: 'https://radiorecord.ru/station/nu-dance' },
    { id: 'cadillac', name: '60\'s Dance', desc: 'Танцевальная музыка эпохи рок-н-ролла', url: 'https://radiorecord.hostingradio.ru/cadillac96.aacp', homepage: 'https://radiorecord.ru/station/cadillac' },
    { id: 'lady-waks', name: 'Lady Waks', desc: 'Радиошоу от первой леди breaks-ритмов', url: 'https://radiorecord.hostingradio.ru/ladywaks96.aacp', homepage: 'https://radiorecord.ru/station/lady-waks' },
    { id: 'dc', name: 'Dancecore', desc: 'Dance на скорости до 150bpm', url: 'https://radiorecord.hostingradio.ru/dc96.aacp', homepage: 'https://radiorecord.ru/station/dc' },
    { id: 'fut', name: 'Future House', desc: 'Future и Jackin\' house: Don Diablo, Tchami, Oliver Heldens', url: 'https://radiorecord.hostingradio.ru/fut96.aacp', homepage: 'https://radiorecord.ru/station/fut' },
    { id: 'darkside', name: 'Darkside', desc: 'Тёмная сторона drum\'n\'bass: Noisia, Panacea, Limewax', url: 'https://radiorecord.hostingradio.ru/darkside96.aacp', homepage: 'https://radiorecord.ru/station/darkside' },
    { id: 'futurerave', name: 'Future Rave', desc: 'Включай и ты на рейве!', url: 'https://radiorecord.hostingradio.ru/futurerave96.aacp', homepage: 'https://radiorecord.ru/station/futurerave' },
    { id: 'reggae', name: 'Reggae', desc: 'Танцевальный вайб с берегов Ямайки', url: 'https://radiorecord.hostingradio.ru/reggae96.aacp', homepage: 'https://radiorecord.ru/station/reggae' },
    { id: 'elect', name: 'Electro', desc: 'Лучшее в Electro-house: Wolfgang Gartner, Knife Party, Curbi', url: 'https://radiorecord.hostingradio.ru/elect96.aacp', homepage: 'https://radiorecord.ru/station/elect' },
    { id: 'teo', name: 'Hardstyle', desc: 'Маршевый бас и мелодичный лид: бескомпромиссная смесь', url: 'https://radiorecord.hostingradio.ru/teo96.aacp', homepage: 'https://radiorecord.ru/station/teo' },
    { id: 'dub', name: 'Dubstep', desc: 'Басы на максимум!', url: 'https://radiorecord.hostingradio.ru/dub96.aacp', homepage: 'https://radiorecord.ru/station/dub' },
    { id: 'progr', name: 'Progressive', desc: 'Лучшее из progressive trance & house', url: 'https://radiorecord.hostingradio.ru/progr96.aacp', homepage: 'https://radiorecord.ru/station/progr' },
    { id: 'nejtrinobaur', name: 'Nejtrino & Baur', desc: 'Радиошоу от резидентов Радио Record', url: 'https://radiorecord.hostingradio.ru/nejtrinobaur96.aacp', homepage: 'https://radiorecord.ru/station/nejtrinobaur' },
    { id: 'synth', name: 'Synthwave', desc: 'Вайб в стиле электронной музыки 80-х', url: 'https://radiorecord.hostingradio.ru/synth96.aacp', homepage: 'https://radiorecord.ru/station/synth' },
    { id: 'latina', name: 'Latina Dance', desc: 'Despacito, Gazolina, Danza Kuduro и подобное', url: 'https://radiorecord.hostingradio.ru/latina96.aacp', homepage: 'https://radiorecord.ru/station/latina' },
    { id: 'dj-gvozd', name: 'DJ Gvozd', desc: 'Легендарное радиошоу о d\'n\'b музыке', url: 'https://radiorecord.hostingradio.ru/djgvozd96.aacp', homepage: 'https://radiorecord.ru/station/dj-gvozd' },
    { id: 'edmhits', name: 'EDM Classics', desc: 'Фестивальные гимны', url: 'https://radiorecord.hostingradio.ru/edmhits96.aacp', homepage: 'https://radiorecord.ru/station/edmhits' },
    { id: 'tecktonik', name: 'Tecktonik', desc: 'Стиль, породивший танцевальный бум 2000-х', url: 'https://radiorecord.hostingradio.ru/tecktonik96.aacp', homepage: 'https://radiorecord.ru/station/tecktonik' },
    { id: 'jungle', name: 'Jungle', desc: 'История и современность jungle-музыки: DJ Hype, Shy FX, Ed Rush', url: 'https://radiorecord.hostingradio.ru/jungle96.aacp', homepage: 'https://radiorecord.ru/station/jungle' },
    { id: 'hypno', name: 'Hypnotic', desc: 'Идеальный бэкграунд для работы или поездки в авто', url: 'https://radiorecord.hostingradio.ru/hypno96.aacp', homepage: 'https://radiorecord.ru/station/hypno' },
    { id: 'uk-garage', name: 'UK Garage', desc: 'Атмосфера клубов восточного Лондона конца 90-х', url: 'https://radiorecord.hostingradio.ru/ukgarage96.aacp', homepage: 'https://radiorecord.ru/station/uk-garage' },
    { id: 'gast', name: 'Гастарбайтер FM', desc: 'Первоапрельский спецпроект', url: 'https://radiorecord.hostingradio.ru/gast96.aacp', homepage: 'https://radiorecord.ru/station/gast' },
    { id: 'mt', name: 'Midtempo', desc: 'Dance на минималках', url: 'https://radiorecord.hostingradio.ru/mt96.aacp', homepage: 'https://radiorecord.ru/station/mt' },
    { id: 'fbass', name: 'Future Bass', desc: 'Flume, Illenium, Marshmello', url: 'https://radiorecord.hostingradio.ru/fbass96.aacp', homepage: 'https://radiorecord.ru/station/fbass' },
    { id: 'martingarrix', name: 'Martin Garrix', desc: 'Радиошоу STMPD от Martin Garrix', url: 'https://radiorecord.hostingradio.ru/martingarrix96.aacp', homepage: 'https://radiorecord.ru/station/martingarrix' },
    { id: 'oliverheldens', name: 'Oliver Heldens', desc: 'Радиошоу Heldeep от знаменитого голландского DJ', url: 'https://radiorecord.hostingradio.ru/oliverheldens96.aacp', homepage: 'https://radiorecord.ru/station/oliverheldens' },
    { id: 'mmbt', name: 'Moombahton', desc: 'Синтез house- и reggae-ритмов.', url: 'https://radiorecord.hostingradio.ru/mmbt96.aacp', homepage: 'https://radiorecord.ru/station/mmbt' },
    { id: '2step', name: '2-step', desc: 'Атмосферные синкопированные ритмы', url: 'https://radiorecord.hostingradio.ru/2step96.aacp', homepage: 'https://radiorecord.ru/station/2step' },
    { id: 'complextro', name: 'Complextro', desc: 'Синтез house и dubstep', url: 'https://radiorecord.hostingradio.ru/complextro96.aacp', homepage: 'https://radiorecord.ru/station/complextro' },
    { id: 'groovetribal', name: 'Groove/Tribal', desc: 'Этнический бит', url: 'https://radiorecord.hostingradio.ru/groovetribal96.aacp', homepage: 'https://radiorecord.ru/station/groovetribal' },
    { id: 'christmas-chill', name: 'Christmas Chill', desc: 'Downtempo-бит для тёплого новогоднего уюта', url: 'https://radiorecord.hostingradio.ru/christmaschill96.aacp', homepage: 'https://radiorecord.ru/station/christmas-chill' },
    { id: 'christmas-radio', name: 'Christmas', desc: 'Популярные новогодние и рождественские треки', url: 'https://radiorecord.hostingradio.ru/christmas96.aacp', homepage: 'https://radiorecord.ru/station/christmas-radio' },
    { id: 'ruszima', name: 'Русская Зима', desc: 'Родные согревающие песни', url: 'https://radiorecord.hostingradio.ru/ruszima96.aacp', homepage: 'https://radiorecord.ru/station/ruszima' }
  ]

  PersistentProperties {
    id: state
    reloadableId: "worldradio-state"
    property int volume: root.defaultVolume
    property string stationUuid: ""
    property string stationName: ""
    property string stationUrl: ""
    property bool playing: false
    // Expand (today's full two-pane browser) vs Compact (hero + transport +
    // volume only, panel shrunk to fit). Same persistence tier as every
    // other field above: survives a shell config reload, not a full
    // restart — see docs/expand-compact-view-research.md.
    property bool compactView: false
    // Deep bass (mpv's `bass` audio filter, fixed gain, see CONTEXT.md for
    // why this isn't called "Bass boost") — a listener preference, same
    // persistence tier as compactView above, not reset per stream the way
    // nowPlayingGenre is.
    property bool deepBassEnabled: false
  }

  property bool paused: false
  property string nowPlayingTitle: ""
  // Arrives on the exact same already-registered "metadata" observe_property
  // as nowPlayingTitle (icy-genre, not a separate IPC call) — not every
  // station sends it, so this tolerates being empty the same way
  // nowPlayingTitle already does.
  property string nowPlayingGenre: ""
  property bool buffering: false
  property int bufferingPercent: 0

  // Sleep timer selection: "off" | "15" | "30" | "60". Transient — a shell
  // config reload (rare mid-timer) resetting a pending sleep timer is an
  // acceptable edge case, the same tier as any other transient here.
  property string sleepTimerOption: "off"

  // True for the one mpvProc.exited that fires because playStation() killed
  // the previous station to switch to a new one. Killing an external process
  // is asynchronous, so that exit signal can land after the new station has
  // already started — without this guard, onExited's "really stopped" reset
  // would clobber state.playing (disabling Stop/Pause) and cancel the new
  // station's socket reconnect, even though it's actively playing.
  property bool switchingStation: false

  // Free-text station-name filter, matched against the static station
  // list locally (name and description). Transient (not in `state`):
  // cleared on a shell restart.
  property string nameQuery: ""

  property string ipcSocketPath: ""

  // Starred stations, keyed by stationuuid: { uuid, name, playUrl, codec,
  // bitrate, tags }. PersistentProperties (see `state` above) only survives
  // in-process QML reloads, not a real shell restart — confirmed by the
  // absence of any on-disk state for it and by the first-party notifications
  // service's own comment to that effect. Favorites need to actually survive
  // a restart to be worth starring, so they get their own on-disk file
  // instead, following that same service's FileView + debounced-save pattern.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/"
  readonly property string favoritesPath: stateDir + "world-radio-favorites.json"
  property var favorites: ({})
  property bool favoritesLoaded: false
  // Bounds enforced on the favorites file itself (see favoritesReadProc)
  // and on every entry loaded from or written to it. The path is fixed and
  // predictable, so nothing should ever hand its raw content to JSON.parse
  // or the model without these checked first: a hostile or corrupted
  // replacement (a FIFO swapped in at that path, or just an oversized file)
  // must not be able to block or balloon the shell's memory.
  readonly property int maxFavoritesFileBytes: 1048576
  readonly property int maxFavorites: 500

  // History: the most recently played stations, most-recent-first — see
  // docs/adr/0001-history-separate-file.md for why this isn't just a
  // second key in the favorites file above. Same on-disk safety tier as
  // Favorites (hardenedFileReadScript below is shared by both), but its
  // own file, own bounds, own lifecycle (fully automatic, always trimmed —
  // never user-curated the way Favorites is.
  readonly property string historyPath: stateDir + "world-radio-history.json"
  property var history: []
  property bool historyLoaded: false
  readonly property int maxHistoryFileBytes: 1048576
  readonly property int maxHistory: 15
  // History's own row height cap — independent of maxHistory (how many
  // entries are kept) so the section can never push the filter pickers
  // below it further down the column as it fills toward that cap; past
  // this many rows it scrolls internally instead of growing.
  readonly property int historyVisibleRows: 5
  readonly property int favoritesVisibleRows: 5

  ListModel { id: stationsModel }
  ListModel { id: favoritesModel }

  Process { id: ensureStateDirProc; command: ["mkdir", "-p", root.stateDir]; running: false }

  // Earlier versions of this read went through progressively narrower gaps:
  // a separate stat-by-path then FileView.reload() (two path lookups, so
  // the path could be repointed between them); then a single bash fd
  // (exec 3<> "$path") checked via /proc/self/fd/3 — which closed that
  // race but still transparently followed a symlink at favoritesPath,
  // since plain open()/bash redirection has no way to refuse one.
  //
  // Bash's redirection operators can't express O_NOFOLLOW, so this uses
  // Python's os.open() to get the real flags: O_NOFOLLOW makes the open
  // itself fail if favoritesPath's final component is a symlink (rather
  // than silently reading whatever it points to), and O_NONBLOCK makes
  // opening a FIFO return immediately instead of blocking for a reader.
  // Every check after that — regular-file, size — runs via fstat() on the
  // already-open fd, and the read is capped at maxFavoritesFileBytes, so
  // nothing about the path is ever consulted a second time and nothing
  // past the cap is ever read off disk.
  //
  // Verified locally against all five cases before shipping: missing path,
  // a valid file, an oversized file, a FIFO with no writer, and a symlink
  // to an otherwise-legitimate regular file elsewhere — only the valid
  // file's content comes back; everything else exits non-zero with no
  // stdout, which loadFavorites("")/loadHistory("") already treat as
  // "nothing saved yet". Parameterized by path/max_bytes (argv), so
  // historyReadProc below reuses this exact script for a second file
  // rather than duplicating the hardening.
  readonly property string hardenedFileReadScript: `
import os, sys, stat as statmod
path, max_bytes = sys.argv[1], int(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    if not statmod.S_ISREG(st.st_mode) or st.st_size > max_bytes:
        sys.exit(1)
    chunks, remaining = [], max_bytes
    while remaining > 0:
        chunk = os.read(fd, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    sys.stdout.buffer.write(b"".join(chunks))
except OSError:
    sys.exit(1)
finally:
    os.close(fd)
  `

  Process {
    id: favoritesReadProc
    command: ["python3", "-c", root.hardenedFileReadScript, root.favoritesPath, String(root.maxFavoritesFileBytes)]
    stdout: StdioCollector {
      // Empty on any failure branch above (missing path, symlink, non-
      // regular, oversized) — loadFavorites("") already treats that as
      // "no favorites yet", so no separate exit-code handling is needed.
      onStreamFinished: root.loadFavorites(String(text || ""))
    }
  }

  Process {
    id: historyReadProc
    command: ["python3", "-c", root.hardenedFileReadScript, root.historyPath, String(root.maxHistoryFileBytes)]
    stdout: StdioCollector {
      onStreamFinished: root.loadHistory(String(text || ""))
    }
  }

  // Write-only: setText()/atomicWrites for persisting favorites back out.
  // Reading goes through favoritesReadProc instead, never through this.
  FileView {
    id: favoritesFile
    path: root.favoritesPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Same write-only shape as favoritesFile above, for History's own file.
  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: favoritesSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushFavorites()
  }

  Timer {
    id: historySaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushHistory()
  }

  // Debounces the name-search field so a re-filter fires ~350ms after the
  // last keystroke rather than on every character.
  Timer {
    id: nameSearchTimer
    interval: 350
    repeat: false
    onTriggered: root.applyFilter()
  }

  // Shared uuid/name/playUrl/codec/bitrate/tags/homepage bounds — applied
  // whether the row just came from the static list (toggleFavorite/
  // recordHistory) or from disk (loadFavorites/loadHistory), so a future
  // change to a bound (a new field, a different length cap) has one place
  // to make it instead of four. Callers needing an authoritative uuid
  // other than row.uuid (see loadFavorites, which trusts the favorites
  // file's own map key over whatever a hand-edited entry's embedded uuid
  // might claim) pass it via uuidOverride rather than relying on row.uuid.
  function sanitizeStationRow(row, uuidOverride) {
    return {
      uuid: String(uuidOverride !== undefined ? uuidOverride : (row.uuid || "")).slice(0, 64),
      name: String(row.name || "").slice(0, 200),
      playUrl: String(row.playUrl || "").slice(0, 2000),
      codec: String(row.codec || "").slice(0, 32),
      bitrate: Math.max(0, Math.min(9999999, Number(row.bitrate) || 0)),
      tags: String(row.tags || "").slice(0, 500),
      homepage: String(row.homepage || "").slice(0, 2000)
    }
  }

  // Shared by loadFavorites/loadHistory — a hand-edited or corrupted file
  // shouldn't be able to hand mpv a non-http(s) URL or an empty identity.
  function isValidStationRow(safe) {
    return !!(safe.uuid && safe.name && /^https?:\/\//i.test(safe.playUrl))
  }

  function loadFavorites(raw) {
    if (root.favoritesLoaded) return
    var parsed = {}
    var count = 0
    try {
      var data = JSON.parse(raw || "")
      if (data && typeof data === "object" && data.favorites && typeof data.favorites === "object") {
        for (var uuid in data.favorites) {
          if (count >= root.maxFavorites) break
          var f = data.favorites[uuid]
          if (!f || typeof f !== "object") continue
          // Re-validated on load, not just on write — a hand-edited or
          // corrupted file shouldn't be able to hand mpv a non-http(s) URL.
          var safe = root.sanitizeStationRow(f, uuid)
          if (!root.isValidStationRow(safe)) continue
          parsed[safe.uuid] = safe
          count++
        }
      }
    } catch (e) { }
    root.favorites = parsed
    root.favoritesLoaded = true
  }

  function flushFavorites() {
    favoritesFile.setText(JSON.stringify({ version: 1, favorites: root.favorites }, null, 2) + "\n")
  }

  function scheduleFavoritesSave() {
    if (!root.favoritesLoaded) return
    favoritesSaveTimer.restart()
  }

  // History is an ordered array (most-recent-first), unlike favorites'
  // uuid-keyed map — order is the whole point here, where favorites has
  // none. Re-validated on load for the same reason as loadFavorites above:
  // a hand-edited or corrupted file shouldn't be able to hand mpv a
  // non-http(s) URL.
  function loadHistory(raw) {
    if (root.historyLoaded) return
    var parsed = []
    try {
      var data = JSON.parse(raw || "")
      if (data && typeof data === "object" && Array.isArray(data.history)) {
        for (var i = 0; i < data.history.length && parsed.length < root.maxHistory; i++) {
          var h = data.history[i]
          if (!h || typeof h !== "object") continue
          var safe = root.sanitizeStationRow(h)
          if (!root.isValidStationRow(safe)) continue
          parsed.push(safe)
        }
      }
    } catch (e) { }
    root.history = parsed
    root.historyLoaded = true
  }

  function flushHistory() {
    historyFile.setText(JSON.stringify({ version: 1, history: root.history }, null, 2) + "\n")
  }

  function scheduleHistorySave() {
    if (!root.historyLoaded) return
    historySaveTimer.restart()
  }

  // Records a play in History: bumps an already-present station back to
  // the top instead of duplicating it (a listener replaying their one
  // favorite station shouldn't push everything else out), then trims to
  // maxHistory. Called from playStation() for every successful play.
  //
  // Guarded on historyLoaded, same as scheduleHistorySave() below — not
  // just to skip an unnecessary disk write, but because loadHistory()
  // unconditionally overwrites root.history the first time it runs
  // (guarded only by that same flag). Recording a play before the initial
  // disk read completes would otherwise be silently wiped out the moment
  // that read finishes and calls loadHistory().
  function recordHistory(row) {
    if (!root.historyLoaded || !row || !row.uuid) return
    var next = [root.sanitizeStationRow(row)]
    for (var i = 0; i < root.history.length; i++) {
      if (root.history[i].uuid !== row.uuid) next.push(root.history[i])
    }
    if (next.length > root.maxHistory) next.length = root.maxHistory
    root.history = next
    root.scheduleHistorySave()
  }

  function isFavorite(uuid) {
    return Object.prototype.hasOwnProperty.call(root.favorites, uuid)
  }

  function toggleFavorite(row) {
    if (!row || !row.uuid) return
    var next = {}
    for (var k in root.favorites) next[k] = root.favorites[k]
    if (next[row.uuid]) {
      delete next[row.uuid]
    } else if (Object.keys(next).length < root.maxFavorites) {
      next[row.uuid] = root.sanitizeStationRow(row)
    }
    root.favorites = next
    root.scheduleFavoritesSave()
    root.resortStations()
  }

  // The right pane lists every station in directory order; favorites live
  // in their own FAVORITES section in the left column (above History).
  // This rebuilds that section after a filter pass and whenever a favorite
  // is toggled, so starring a station puts it into the section live.
  function resortStations() {
    favoritesModel.clear()
    for (var uuid in root.favorites) {
      var f = root.favorites[uuid]
      favoritesModel.append({ uuid: f.uuid, name: f.name, playUrl: f.playUrl, codec: f.codec, bitrate: f.bitrate, tags: f.tags, homepage: f.homepage })
    }
  }

  Component.onCompleted: {
    var runtimeDir = Quickshell.env("XDG_RUNTIME_DIR")
    ipcSocketPath = (runtimeDir && runtimeDir.length > 0 ? runtimeDir : "/tmp") + "/omarchy-worldradio-" + Math.floor(Math.random() * 1e9) + ".sock"

    ensureStateDirProc.running = true
    Qt.callLater(function() { favoritesReadProc.running = true })
    Qt.callLater(function() { historyReadProc.running = true })
  }

  onOpenedChanged: {
    // The static list is always "loaded" — just populate it once, and
    // re-apply whatever name filter is active.
    if (root.opened && stationsModel.count === 0) root.applyFilter()
  }

  // Fills the list from the built-in static directory, applying the
  // active name filter (matched against name and description, case-
  // insensitively), favorites kept at the top.
  function applyFilter() {
    var q = root.nameQuery.trim().toLowerCase()
    var rows = []
    for (var i = 0; i < root.staticStations.length; i++) {
      var s = root.staticStations[i]
      if (q !== "" && s.name.toLowerCase().indexOf(q) === -1 && s.desc.toLowerCase().indexOf(q) === -1) continue
      var safe = root.sanitizeStationRow({
        uuid: s.id,
        name: s.name,
        playUrl: s.url,
        codec: "AAC",
        bitrate: 96,
        tags: s.desc,
        homepage: s.homepage
      })
      if (!root.isValidStationRow(safe)) continue
      rows.push(safe)
    }
    stationsModel.clear()
    for (var j = 0; j < rows.length; j++) stationsModel.append(rows[j])
    root.resortStations()
  }

  // Pure layout/sizing switch — never touches playback, filters, or the
  // loaded station list, so nothing here needs a reload.
  function toggleCompactView() {
    state.compactView = !state.compactView
  }

  // One-shot reorder of the current list, in place — no fetch involved.
  // resortStations() afterwards keeps the favorites group above the rest.
  function shuffleStations() {
    if (stationsModel.count === 0) return
    var rows = []
    for (var i = 0; i < stationsModel.count; i++) {
      var r = stationsModel.get(i)
      rows.push({ uuid: r.uuid, name: r.name, playUrl: r.playUrl, codec: r.codec, bitrate: r.bitrate, tags: r.tags, homepage: r.homepage })
    }
    for (var j = rows.length - 1; j > 0; j--) {
      var k = Math.floor(Math.random() * (j + 1))
      var tmp = rows[j]
      rows[j] = rows[k]
      rows[k] = tmp
    }
    stationsModel.clear()
    for (var m = 0; m < rows.length; m++) stationsModel.append(rows[m])
    root.resortStations()
  }

  // "off" cancels outright; "15"/"30"/"60" (re)starts a fresh countdown,
  // replacing whatever was pending before.
  function setSleepTimer(option) {
    root.sleepTimerOption = option
    sleepTimer.stop()
    if (option !== "off") {
      sleepTimer.interval = Number(option) * 60000
      sleepTimer.start()
    }
  }

  function cancelSleepTimer() {
    if (root.sleepTimerOption === "off") return
    root.sleepTimerOption = "off"
    sleepTimer.stop()
  }

  // Plays a random station from the built-in static list — a click on the
  // bar icon's 🎲 button. Clears the name filter first so nothing about
  // the visible search state suggests this was a filtered pick.
  function surpriseMe() {
    if (root.staticStations.length === 0) return
    nameField.text = ""
    root.nameQuery = ""
    var pick = root.staticStations[Math.floor(Math.random() * root.staticStations.length)]
    root.playStation({
      uuid: pick.id,
      name: pick.name,
      playUrl: pick.url,
      codec: "AAC",
      bitrate: 96,
      tags: pick.desc,
      homepage: pick.homepage
    })
    root.notifyStationChange()
  }

  // Shared by the bar icon's tooltip and the panel's now-playing caption
  // Text — combining title/genre in one place instead of two keeps both
  // "now playing" surfaces in sync instead of one silently falling behind
  // the other when a new metadata field is added later.
  function nowPlayingCaption() {
    return [root.nowPlayingTitle, root.nowPlayingGenre].filter(function(s) { return s }).join(" · ")
  }

  // Shared by playStation(), stopPlayback(), and mpvProc.onExited's
  // "really stopped" cleanup: every piece of mpv-observed playback display
  // state, reset together so a future observed property can't be added to
  // one reset site and forgotten in another.
  function resetPlaybackDisplay() {
    root.paused = false
    root.nowPlayingTitle = ""
    root.nowPlayingGenre = ""
    root.buffering = false
    root.bufferingPercent = 0
  }

  // Takes the full row (uuid/name/playUrl/codec/bitrate/tags), not just the
  // three fields playback itself needs — every call site already has the
  // full row on hand, and recordHistory() below needs codec/bitrate/tags
  // too, so widening this beats re-deriving them from a bare uuid/name/url.
  function playStation(row) {
    if (!row || !/^https?:\/\//i.test(row.playUrl)) return
    state.stationUuid = row.uuid
    state.stationName = row.name
    state.stationUrl = row.playUrl
    state.playing = true
    root.resetPlaybackDisplay()
    root.cancelSleepTimer()
    root.recordHistory(row)

    if (mpvProc.running) root.switchingStation = true
    ipcSocket.connected = false
    mpvProc.running = false
    Qt.callLater(function() {
      mpvProc.running = true
      ipcRetryTimer.attempts = 0
      ipcRetryTimer.restart()
    })
  }

  // Steps to the previous/next station in the currently loaded list, like
  // turning a tuning dial. Starts from the top of the list if nothing (or
  // something no longer in the list) is playing.
  function playRelativeStation(delta) {
    if (stationsModel.count === 0) return
    var idx = -1
    for (var i = 0; i < stationsModel.count; i++) {
      if (stationsModel.get(i).uuid === state.stationUuid) { idx = i; break }
    }
    var nextIdx = idx === -1 ? 0 : (idx + delta + stationsModel.count) % stationsModel.count
    root.playStation(stationsModel.get(nextIdx))
    root.notifyStationChange()
  }

  function togglePause() {
    if (!state.playing || !ipcSocket.connected) return
    root.paused = !root.paused
    ipcSocket.write(JSON.stringify({ command: ["set_property", "pause", root.paused] }) + "\n")
    ipcSocket.flush()
  }

  // Unlike togglePause() above, this always flips the persisted preference
  // even with nothing playing — a listener can set it before ever hitting
  // play. Applied immediately on a live connection too, so toggling mid-
  // stream is heard right away rather than only on the next station.
  // ipcSocket.onConnectionStateChanged re-applies it on every future
  // connection, the same way loudnorm already is, so the preference
  // survives a station change without needing to be reapplied here again.
  function toggleDeepBass() {
    state.deepBassEnabled = !state.deepBassEnabled
    if (ipcSocket.connected) {
      ipcSocket.write(JSON.stringify({ command: ["af", state.deepBassEnabled ? "add" : "remove", root.deepBassFilter] }) + "\n")
      ipcSocket.flush()
    }
  }

  function stopPlayback() {
    if (ipcSocket.connected) {
      ipcSocket.write(JSON.stringify({ command: ["quit"] }) + "\n")
      ipcSocket.flush()
    }
    ipcRetryTimer.stop()
    mpvProc.running = false
    ipcSocket.connected = false
    state.playing = false
    root.resetPlaybackDisplay()
    root.cancelSleepTimer()
  }

  function handleMpvMessage(line) {
    // Guards against a message already in flight when the socket was torn
    // down to switch stations (playStation()/stopPlayback() both flip
    // ipcSocket.connected synchronously before this could fire again) from
    // clobbering the state the panel already reset for the new station.
    if (!ipcSocket.connected) return
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (!msg || msg.event !== "property-change") return
    if (msg.id === root.metadataObserveId && msg.data && typeof msg.data === "object") {
      // mpv sends this immediately on observe_property registration (with
      // the current value) and again on every future change, so this alone
      // covers both the initial seed and instant live updates — confirmed
      // against mpv's own client.h: "You always get an initial change
      // notification."
      root.nowPlayingTitle = String(msg.data["icy-title"] || "")
      root.nowPlayingGenre = String(msg.data["icy-genre"] || "")
    } else if (msg.id === root.pauseObserveId && typeof msg.data === "boolean") {
      // Keeps the Pause/Resume label correct even when playback was toggled
      // from a hardware media key or another MPRIS controller, not this panel.
      root.paused = msg.data
    } else if (msg.id === root.pausedForCacheObserveId && typeof msg.data === "boolean") {
      root.buffering = msg.data
    } else if (msg.id === root.cacheBufferingStateObserveId && typeof msg.data === "number") {
      // Documented as 0-100, but clamped the same way other externally
      // sourced numbers in this file already are (e.g. bitrate), rather
      // than trusting it unconditionally.
      root.bufferingPercent = Math.max(0, Math.min(100, msg.data))
    }
  }

  // Station name only — no genre (nowPlayingGenre arrives asynchronously
  // over mpv's IPC after playback starts, later than this fires) and a
  // generic stock icon rather than any station artwork (no download-and-
  // cache mechanism exists in this codebase for that).
  Process {
    id: notifyProc
    // "--" ends option parsing (confirmed live against this machine's
    // notify-send) — state.stationName is untrusted, API-sourced text;
    // without it, a station name starting with "-" could be parsed as a
    // notify-send flag instead of displayed as the notification body.
    command: ["notify-send", "-a", "Радио", "-i", "audio-x-generic", "-t", "3000", "--", "Сейчас играет", state.stationName]
  }

  // Fired only for station changes the listener didn't directly click
  // (Prev/Next, Surprise) — a direct row click already shows them exactly
  // what they picked, so notifying there would be redundant. Not called
  // for Shuffle: shuffleStations() only reorders the visible list, it
  // never changes what's actually playing.
  function notifyStationChange() {
    notifyProc.running = false
    Qt.callLater(function() { notifyProc.running = true })
  }

  Process {
    id: mpvProc
    command: ["mpv", "--no-video", "--idle=yes", "--really-quiet",
      "--input-ipc-server=" + root.ipcSocketPath,
      "--volume=" + Math.max(0, Math.min(root.volumeCeiling, state.volume)), state.stationUrl]
    onExited: function(code, status) {
      if (root.switchingStation) {
        // Expected: playStation() killed this instance to start the next
        // station, which is already (re)starting on its own. Nothing here
        // belongs to that new station's lifecycle, so touch nothing else.
        root.switchingStation = false
        return
      }
      ipcRetryTimer.stop()
      ipcSocket.connected = false
      state.playing = false
      root.resetPlaybackDisplay()
      root.cancelSleepTimer()
    }
  }

  Timer {
    id: ipcRetryTimer
    interval: 400
    repeat: true
    property int attempts: 0
    onTriggered: {
      attempts += 1
      if (ipcSocket.connected || attempts > 20) { stop(); return }
      ipcSocket.path = root.ipcSocketPath
      ipcSocket.connected = true
    }
  }

  // interval is set right before start() in setSleepTimer() below — there's
  // no fixed value here since it depends on which duration was picked.
  Timer {
    id: sleepTimer
    repeat: false
    onTriggered: {
      root.sleepTimerOption = "off"
      root.stopPlayback()
    }
  }

  Socket {
    id: ipcSocket
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleMpvMessage(data) }
    }
    onConnectionStateChanged: {
      if (connected) {
        ipcRetryTimer.stop()
        write(JSON.stringify({ command: ["set_property", "pause", false] }) + "\n")
        // Internet radio streams vary wildly in loudness station-to-station;
        // mpv's bundled loudnorm filter evens that out. Fire-and-forget,
        // same as the pause reset above — no reply is awaited or checked,
        // and a failed af here must never block playback from starting.
        // Confirmed against mpv's own input.rst: the runtime command is
        // `af <operation> <value>` ("add" to append to the filter chain) —
        // there is no separate "af-add" command in the JSON IPC protocol.
        write(JSON.stringify({ command: ["af", "add", "lavfi=[loudnorm]"] }) + "\n")
        // Each station change spawns a fresh mpv instance (see
        // playStation()) with no filters carried over, so a standing Deep
        // bass preference needs re-applying on every new connection too —
        // unlike loudnorm above, only when the listener actually has it on.
        if (state.deepBassEnabled) {
          write(JSON.stringify({ command: ["af", "add", root.deepBassFilter] }) + "\n")
        }
        // Registered once per connection. mpv sends an immediate
        // property-change event with the current value on registration
        // (per its own client.h docs), then another on every future
        // change — so this alone seeds state on connect *and* keeps it
        // instantly in sync, with no separate get_property call needed.
        write(JSON.stringify({ command: ["observe_property", root.metadataObserveId, "metadata"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", root.pauseObserveId, "pause"] }) + "\n")
        // Surfaces real "Buffering…" feedback during the connection gap
        // (or a later rebuffer) instead of leaving that window blank —
        // confirmed live against a real mpv instance and stream.
        write(JSON.stringify({ command: ["observe_property", root.pausedForCacheObserveId, "paused-for-cache"] }) + "\n")
        write(JSON.stringify({ command: ["observe_property", root.cacheBufferingStateObserveId, "cache-buffering-state"] }) + "\n")
        flush()
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐹"
    active: state.playing
    tooltipText: state.playing
      ? ("Играет: " + state.stationName + (root.buffering
          ? (" — Буферизация… " + root.bufferingPercent + "%")
          : (root.nowPlayingCaption() ? " — " + root.nowPlayingCaption() : "")))
      : "Радио"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.stopPlayback()
      else if (b === Qt.MiddleButton) root.togglePause()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Two panes side by side: a fixed-width left column for the pickers,
    // and a right pane that gets whatever's left for the station list — so
    // the list isn't squeezed into whatever's left below a tall stack of
    // controls. Compact drops the right pane and most of the left column,
    // so it gets its own, much narrower width instead: the fixed 320px
    // column plus the card's real horizontal insets on both sides (border
    // + popup padding, ~16px each at default theme settings — confirmed
    // against KeyboardPanel/BorderSurface's own contentLeftInset/
    // contentRightInset, not guessed), so the column doesn't crowd the
    // card's border. See docs/expand-compact-view-research.md.
    contentWidth: panel.fittedContentWidth(state.compactView ? Style.space(352) : Style.space(780))
    // Expand: a deliberately oversized desired height clamps to
    // availableCardHeight inside fittedContentHeight — i.e. the panel
    // always grows to fill the screen down to the bar/margins, so the
    // station list below gets all the leftover room instead of a small
    // fixed-height peephole.
    // Compact: no station list to fill room for, so — like every other
    // Omarchy shell panel — the real content column's own implicitHeight
    // is passed instead, and the panel shrinks to fit it.
    contentHeight: panel.fittedContentHeight(state.compactView ? leftColumnContent.implicitHeight : Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        anchors.fill: parent

        // Scrolls independently of the station list on the right (which
        // already scrolls via its own ListView) — the column has grown
        // past what fits on screen as pickers were added over time, and
        // without this, content past the visible edge (e.g. the language
        // filter) is simply unreachable rather than clipped or scrollable.
        // Matches the shell's own audio panel's shape (a PanelSlider inside
        // a scrollable settings column): ScrollView with a Binding gating
        // interactivity by actual overflow, plus a scrollbar that only
        // appears when there's something to scroll, rather than an ad hoc
        // Flickable.
        ScrollView {
          id: leftColumn
          width: Style.space(320)
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          ScrollBar.vertical.policy: leftColumnContent.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

          // The audio panel's own PanelSliders don't guard against this,
          // but its consequence turned out worse than a cut-short drag:
          // PanelSlider's `dragging` flag has no onCanceled, only
          // onReleased, so a grab stolen mid-drag by this ScrollView's
          // Flickable leaves `dragging` stuck true permanently — its knob
          // then never reflects `state.volume` again (onValueChanged only
          // updates the visible position `if (!dragging)`), not just a
          // one-off interrupted gesture. Unlike PanelSlider.qml itself
          // (a shared qs.Ui component, not this plugin's to change),
          // suppressing this container's interactivity for the duration
          // of a drag is entirely within this file, so there's no reason
          // to accept the same latent risk here once it's understood.
          Binding {
            target: leftColumn.contentItem
            property: "interactive"
            value: leftColumnContent.implicitHeight > leftColumn.height && !volumeSlider.dragging
          }

          Column {
            id: leftColumnContent
            width: leftColumn.availableWidth
            spacing: Style.space(12)

            // ---------- Now playing hero ----------
            Item {
              width: parent.width
              implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

              Text {
                id: heroIcon
                text: "󰐹"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Always reachable in both modes, unlike every other control
              // in this column — it's the only way back to Expand once
              // Compact has hidden everything else.
              Text {
                id: modeToggle
                text: state.compactView ? "Развернуть" : "Свернуть"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleCompactView()
                }
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: modeToggle.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "Радио"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  text: state.playing ? state.stationName : "Не играет"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  visible: root.buffering || root.nowPlayingCaption() !== ""
                  text: root.buffering
                    ? ("Buffering… " + root.bufferingPercent + "%")
                    : root.nowPlayingCaption()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }

            // ---------- Tuning dial: previous / pause / next / stop / surprise ----------
            // Icon-only, content-sized, borderless-at-rest — matches
            // Omarchy's own media-transport widget
            // (plugins/services/media/BarWidget.qml), reusing the identical
            // prev/next glyphs plus its play/pause glyphs (unused elsewhere
            // in this file until now) and its "primary action is slightly
            // larger" treatment for Pause/Resume. Once grew to ten buttons
            // (Sleep timer, Shuffle, and Recently added all landed here
            // over time) and silently overflowed this column's width —
            // Recently added's removal brought it back down to nine,
            // fitting comfortably in one Row again. See
            // docs/compact-transport-buttons-research.md for the original
            // shape, and git history on this comment for the overflow
            // detour if a similar growth spurt happens again.
            //
            // Left-anchored, not centered: leftColumn's vertical ScrollBar
            // is an overlay pinned to this column's true right edge
            // (confirmed by reading the installed Qt Quick Controls Basic
            // style's ScrollView.qml/ScrollBar.qml — never subtracted from
            // available width on its own), so the row's rightmost button
            // could still end up under it when scrolling is active. For a
            // *centered* row, reserving margin by narrowing the container
            // only helps the right edge by giving up an equal amount on
            // the left — a real risk given this row's own left-most
            // buttons (Previous, Play/Pause) have never had much slack to
            // spare either. Left-anchoring sidesteps that trade-off
            // entirely: the left edge stays exactly where it already
            // safely was, and every bit of the row's natural slack shifts
            // to the right edge instead of being split, directly
            // improving clearance on the side that actually needs it.
            Row {
              anchors.left: parent.left
              spacing: Style.space(6)

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒮"
                tooltipText: "Предыдущая станция"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.playRelativeStation(-1)
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.paused ? "󰐊" : "󰏤"
                tooltipText: root.paused ? "Продолжить" : "Пауза"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: state.playing
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.togglePause()
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒭"
                tooltipText: "Следующая станция"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.playRelativeStation(1)
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰓛"
                tooltipText: "Стоп"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: state.playing
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.stopPlayback()
              }

              // A playback control like Stop, not a browsing feature, so —
              // unlike Shuffle below — it stays visible in Compact mode too.
              Button {
                id: sleepTimerButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "💤"
                tooltipText: root.sleepTimerOption === "off"
                  ? "Таймер сна"
                  : "Таймер сна: " + root.sleepTimerOption + " мин"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: root.sleepTimerOption !== "off"
                onClicked: sleepTimerPopup.opened ? sleepTimerPopup.close() : sleepTimerPopup.open()

                Popup {
                  id: sleepTimerPopup
                  parent: sleepTimerButton
                  x: 0
                  y: sleepTimerButton.height + Style.spacing.xxs
                  width: Style.space(110)
                  padding: Style.spacing.hairline
                  focus: true
                  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                  background: BorderSurface {
                    color: Color.popups.background
                    borderSpec: Border.flat(Color.popups.border, Style.normalBorderWidth)
                    radius: Style.cornerRadius
                  }

                  contentItem: Column {
                    id: sleepTimerColumn
                    width: sleepTimerPopup.width - Style.spacing.hairline * 2
                    spacing: Style.spacing.labelGap

                    Repeater {
                      model: [
                        { value: "off", label: "Выкл" },
                        { value: "15", label: "15 мин" },
                        { value: "30", label: "30 мин" },
                        { value: "60", label: "60 мин" }
                      ]
                      delegate: Rectangle {
                        required property var modelData
                        width: sleepTimerColumn.width
                        height: Style.spacing.popupRowHeight
                        color: modelData.value === root.sleepTimerOption
                          ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                          : "transparent"

                        Text {
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.spacing.controlPaddingX
                          anchors.rightMargin: Style.spacing.controlPaddingX
                          text: modelData.label
                          color: modelData.value === root.sleepTimerOption
                            ? Style.hoverStateColor(root.bar.foreground, Color.accent)
                            : root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.setSleepTimer(modelData.value)
                            sleepTimerPopup.close()
                          }
                        }
                      }
                    }
                  }
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "🎲"
                tooltipText: "Случайная станция"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.surpriseMe()
              }

              // Hidden individually (not as a group) — safe here because
              // this Row always has the always-visible buttons above as
              // siblings, so it's never entirely empty in Compact mode.
              Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: !state.compactView
                iconText: "🔀"
                tooltipText: "Перемешать"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: stationsModel.count > 0
                opacity: enabled ? 1.0 : 0.4
                onClicked: root.shuffleStations()
              }
            }

            // Deep bass sits alongside the volume slider (not the Surprise/
            // Shuffle row above) since it's an audio control, not
            // a browsing action — same reasoning as the sleep timer, and
            // likewise visible in both Compact and Expand.
            Row {
              id: volumeRow
              width: parent.width
              spacing: Style.space(8)

              PanelSlider {
                id: volumeSlider
                width: parent.width - deepBassButton.width - volumeRow.spacing
                bar: root.bar
                minimum: 0
                maximum: root.volumeCeiling
                step: 1
                integer: true
                value: state.volume
                // PanelSlider only exposes a single solid fillColor (no
                // built-in two-tone/split fill), so a boosted-past-100%
                // state is signaled by switching the whole fill to
                // Color.urgent rather than forking the shared component to
                // paint just the boosted portion differently.
                fillColor: state.volume > 100 ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
                onMoved: function(v) {
                  state.volume = v
                  if (ipcSocket.connected) {
                    ipcSocket.write(JSON.stringify({ command: ["set_property", "volume", v] }) + "\n")
                    ipcSocket.flush()
                  }
                }
              }

              Button {
                id: deepBassButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "🎧"
                tooltipText: state.deepBassEnabled ? "Низкие: вкл" : "Усиление низких"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                active: state.deepBassEnabled
                onClicked: root.toggleDeepBass()
              }
            }

            // ---------- Expand-only: search and history ----------
            // Same visible:false hide as the sort group above.
            Column {
              width: parent.width
              spacing: Style.space(12)
              visible: !state.compactView

              // Own section, Expand-only, collapses entirely (separator
              // included) until the first play — a listener who's never
              // played anything has nothing to show here yet.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: favoritesModel.count > 0

                PanelSeparator { foreground: root.bar.foreground }
                PanelSectionHeader { text: "ИЗБРАННОЕ"; foreground: root.bar.foreground }

                // Fixed height, capped at favoritesVisibleRows — scrolls
                // internally past that (same clip-and-flick shape as the
                // main station list).
                ListView {
                  id: favoritesList
                  width: parent.width
                  height: Math.min(count, root.favoritesVisibleRows) * (Style.space(28) + spacing) - spacing
                  clip: true
                  spacing: Style.space(2)
                  boundsBehavior: Flickable.StopAtBounds
                  model: favoritesModel

                  delegate: Rectangle {
                    id: favRow
                    required property var modelData
                    width: favoritesList.width
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    color: favMouse.containsMouse
                      ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                      : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.right: favStar.left
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(6)
                      text: favRow.modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    // Click the star in the section to unfavorite — the
                    // row itself plays the station.
                    Text {
                      id: favStar
                      text: "󰓎"
                      color: Color.accent
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleFavorite(favRow.modelData)
                      }
                    }

                    MouseArea {
                      id: favMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.playStation(favRow.modelData)
                    }
                  }
                }
              }

              // Own section, Expand-only, collapses entirely (separator
              // included) until the first play — a listener who's never
              // played anything has nothing to show here yet.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.history.length > 0

                PanelSeparator { foreground: root.bar.foreground }
                PanelSectionHeader { text: "ИСТОРИЯ"; foreground: root.bar.foreground }

                // Fixed height, capped at historyVisibleRows — scrolls
                // internally past that (same clip-and-flick shape as the
                // main station list, no explicit scrollbar there either)
                // instead of growing the whole left column as History
                // fills up toward maxHistory.
                ListView {
                  id: historyList
                  width: parent.width
                  height: Math.min(count, root.historyVisibleRows) * (Style.space(28) + spacing) - spacing
                  clip: true
                  spacing: Style.space(2)
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.history

                  delegate: Rectangle {
                    id: historyRow
                    required property var modelData
                    width: historyList.width
                    height: Style.space(28)
                    radius: Style.cornerRadius
                    color: historyMouse.containsMouse
                      ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                      : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(6)
                      anchors.rightMargin: Style.space(6)
                      text: historyRow.modelData.name
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      id: historyMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.playStation(historyRow.modelData)
                    }
                  }
                }
              }

              PanelSeparator { foreground: root.bar.foreground }
            }
          }
        }

        Rectangle {
          id: columnDivider
          visible: !state.compactView
          width: 1
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          anchors.left: leftColumn.right
          anchors.leftMargin: Style.space(8)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
        }

        // ---------- Right pane: stations get the whole rest of the panel ----------
        // Hidden entirely in Compact — see docs/expand-compact-view-research.md.
        Item {
          id: rightPane
          visible: !state.compactView
          anchors.left: columnDivider.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          // ---------- Поиск над списком станций ----------
          PanelSectionHeader {
            id: searchHeader
            text: "ПОИСК ПО НАЗВАНИЮ"
            foreground: root.bar.foreground
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
          }

          TextField {
            id: nameField
            anchors.top: searchHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            placeholderText: "Название станции…"
            foreground: root.bar.foreground
            onTextChanged: {
              root.nameQuery = text
              nameSearchTimer.restart()
            }
          }

          Text {
            id: matchingText
            anchors.top: nameField.bottom
            anchors.topMargin: Style.space(6)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: root.nameQuery.trim() !== ""
            text: "Найдено по «" + root.nameQuery.trim() + "»"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSectionHeader {
            id: stationsHeader
            text: "СТАНЦИИ"
            foreground: root.bar.foreground
            anchors.top: matchingText.bottom
            anchors.topMargin: Style.space(10)
            anchors.left: parent.left
            anchors.right: parent.right
          }

          Text {
            id: noStationsText
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            visible: stationsModel.count === 0
            text: "Ничего не найдено — попробуй другое название."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Fills every remaining pixel down to the bottom of the panel.
          ListView {
            id: stationsList
            anchors.top: stationsHeader.bottom
            anchors.topMargin: Style.space(8)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: stationsModel.count > 0
            clip: true
            spacing: Style.space(2)
            model: stationsModel

            delegate: Rectangle {
              id: row
              required property string uuid
              required property string name
              required property string playUrl
              required property string codec
              required property int bitrate
              required property string tags
              required property string homepage

              width: stationsList.width
              height: Style.space(44)
              radius: Style.cornerRadius
              color: rowMouse.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                : (state.stationUuid === row.uuid ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent")

              // Row-wide click target underneath everything else, so the
              // star button (declared last, on top) can claim clicks in its
              // own smaller area first.
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.playStation(row)
              }

              Column {
                anchors.left: parent.left
                anchors.right: homepageButton.visible ? homepageButton.left : parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: row.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: [row.tags, row.codec, row.bitrate ? row.bitrate + "kbps" : ""].filter(function(s) { return s }).join(" · ")
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // Absent for a station with no homepage (row.homepage is
              // already "" for anything that wasn't a valid http(s) URL —
              // see applyFilter's own scheme check). The name/caption
              // Column branches on this visibility to reflow into the
              // freed space.
              Text {
                id: homepageButton
                visible: row.homepage !== ""
                text: "🔗"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(20)
                horizontalAlignment: Text.AlignHCenter
                anchors.right: starButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter

                // Same split-the-gap shape as starButton below: expands
                // less toward starButton (its only neighbor) than on every
                // other side.
                MouseArea {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  anchors.leftMargin: -Style.space(6)
                  anchors.rightMargin: -Style.space(3)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Qt.openUrlExternally(row.homepage)
                }
              }

              Text {
                id: starButton
                text: root.isFavorite(row.uuid) ? "󰓎" : "󰓒"
                color: root.isFavorite(row.uuid) ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter

                // Mirrors homepageButton's MouseArea above: expands less
                // toward homepageButton (its only neighbor) than on every
                // other side, so the two hit-areas meet rather than
                // overlap.
                MouseArea {
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: -Style.space(6)
                  anchors.bottomMargin: -Style.space(6)
                  anchors.leftMargin: -Style.space(3)
                  anchors.rightMargin: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleFavorite(row)
                }
              }
            }
          }
        }
      }
    }
  }
}
