> Bu çeviri Claude tarafından oluşturulmuştur. İyileştirme önerileriniz varsa lütfen bir PR açın.

<h1 align="center">cmux</h1>
<p align="center">AI kodlama ajanları için dikey sekmeler ve bildirimler içeren Ghostty tabanlı macOS terminali</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS için cmux'u indir" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | Türkçe | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux ekran görüntüsü" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demo videosu</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Özellikler

<table>
<tr>
<td width="40%" valign="middle">
<h3>Bildirim halkaları</h3>
Kodlama ajanları dikkatinizi istediğinde paneller mavi bir halka alır ve sekmeler yanar
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Bildirim halkaları" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Bildirim paneli</h3>
Bekleyen tüm bildirimleri tek bir yerden görün, en son okunmamışa atlayın
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Kenar çubuğu bildirim rozeti" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Uygulama içi tarayıcı</h3>
<a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>'dan aktarılmış betiklenebilir bir API ile terminalinizin yanında bir tarayıcı bölün
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Yerleşik tarayıcı" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Dikey + yatay sekmeler</h3>
Kenar çubuğu git dalını, bağlantılı PR durumunu/numarasını, çalışma dizinini, dinlenen portları ve en son bildirim metnini gösterir. Yatay ve dikey bölmeler.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Dikey sekmeler ve bölünmüş paneller" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> uzak bir makine için çalışma alanı oluşturur. Tarayıcı panelleri uzak ağ üzerinden yönlendirilir, böylece localhost sorunsuz çalışır. Uzak oturuma bir görsel sürükleyerek scp ile yükleyin.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> Claude Code'un takım arkadaşı modunu tek bir komutla çalıştırır. Takım arkadaşları, kenar çubuğu meta verileri ve bildirimlerle yerel bölmeler olarak oluşturulur. tmux gerekmez.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Tarayıcı içe aktarma** — Chrome, Firefox, Arc ve 20'den fazla tarayıcıdan çerezleri, geçmişi ve oturumları içe aktararak tarayıcı panellerinin oturum açmış şekilde başlamasını sağlayın
- **Özel komutlar** — Komut paletinden başlatılan projeye özel eylemleri [`cmux.json`](https://cmux.com/docs/custom-commands) dosyasında tanımlayın
- **Betiklenebilir** — Çalışma alanları oluşturmak, panelleri bölmek, tuş vuruşları göndermek ve tarayıcıyı otomatikleştirmek için CLI ve socket API
- **Yerel macOS uygulaması** — Swift ve AppKit ile yapılmıştır, Electron değil. Hızlı başlangıç, düşük bellek kullanımı.
- **Ghostty uyumlu** — Temalar, yazı tipleri ve renkler için mevcut `~/.config/ghostty/config` dosyanızı okur
- **GPU hızlandırmalı** — Akıcı görüntüleme için libghostty tarafından desteklenir
- **Klavye kısayolları** — Çalışma alanları, bölmeler, tarayıcı ve daha fazlası için [kapsamlı kısayollar](https://cmux.com/docs/keyboard-shortcuts)
- **Açık kaynak** — Ücretsiz ve GPL lisanslı

## Kurulum

### DMG (önerilen)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="macOS için cmux'u indir" width="180" />
</a>

`.dmg` dosyasını açın ve cmux'u Uygulamalar klasörüne sürükleyin. cmux Sparkle aracılığıyla otomatik güncellenir, bu yüzden yalnızca bir kez indirmeniz yeterlidir.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Daha sonra güncellemek için:

```bash
brew upgrade --cask cmux
```

İlk açılışta macOS, tanımlanmış bir geliştiriciden gelen bir uygulamayı açmayı onaylamanızı isteyebilir. Devam etmek için **Aç**'a tıklayın.

## Neden cmux?

Birçok Claude Code ve Codex oturumunu paralel olarak çalıştırıyorum. Ghostty'yi bir sürü bölünmüş panelle kullanıyor ve bir ajanın bana ne zaman ihtiyacı olduğunu anlamak için yerel macOS bildirimlerine güveniyordum. Ancak Claude Code'un bildirim metni her zaman sadece "Claude is waiting for your input" oluyor, hiçbir bağlam yok ve yeterince sekme açıkken başlıkları bile okuyamıyordum artık.

Birkaç kodlama orkestratörü denedim ama çoğu Electron/Tauri uygulamasıydı ve performansları beni rahatsız ediyordu. Ayrıca terminali tercih ediyorum çünkü GUI orkestratörleri sizi kendi iş akışlarına kilitliyor. Bu yüzden cmux'u Swift/AppKit'te yerel bir macOS uygulaması olarak geliştirdim. Terminal görüntüleme için libghostty kullanıyor ve temalar, yazı tipleri ve renkler için mevcut Ghostty yapılandırmanızı okuyor.

Ana eklemeler kenar çubuğu ve bildirim sistemi. Kenar çubuğunda her çalışma alanı için git dalını, bağlantılı PR durumunu/numarasını, çalışma dizinini, dinlenen portları ve en son bildirim metnini gösteren dikey sekmeler var. Bildirim sistemi terminal dizilerini (OSC 9/99/777) yakalıyor ve Claude Code, OpenCode vb. için ajan kancalarına bağlayabileceğiniz bir CLI'ye (`cmux notify`) sahip. Bir ajan beklerken paneli mavi bir halka alıyor ve sekme kenar çubuğunda yanıyor, böylece bölmeler ve sekmeler arasında hangisinin bana ihtiyacı olduğunu görebiliyorum. Cmd+Shift+U en son okunmamışa atlıyor.

Uygulama içi tarayıcının [agent-browser](https://github.com/vercel-labs/agent-browser)'dan aktarılmış betiklenebilir bir API'si var. Ajanlar erişilebilirlik ağacının anlık görüntüsünü alabilir, öğe referansları elde edebilir, tıklayabilir, formları doldurabilir ve JS çalıştırabilir. Terminalinizin yanında bir tarayıcı paneli bölebilir ve Claude Code'un geliştirme sunucunuzla doğrudan etkileşime girmesini sağlayabilirsiniz.

Her şey CLI ve socket API aracılığıyla betiklenebilir — çalışma alanları/sekmeler oluşturun, panelleri bölün, tuş vuruşları gönderin, tarayıcıda URL'ler açın.

## The Zen of cmux

cmux, geliştiricilerin araçlarını nasıl kullandığını dikte etmez. Bir terminal ve tarayıcı ile CLI'dir, geri kalanı size kalmış.

cmux bir ilkel yapıdır, hazır bir çözüm değil. Size bir terminal, bir tarayıcı, bildirimler, çalışma alanları, bölmeler, sekmeler ve hepsini kontrol etmek için bir CLI verir. cmux sizi kodlama ajanlarını belirli bir şekilde kullanmaya zorlamaz. İlkel yapılarla ne inşa edeceğiniz tamamen size aittir.

En iyi geliştiriciler her zaman kendi araçlarını yapmıştır. Ajanlarla çalışmanın en iyi yolunu henüz kimse bulamadı ve kapalı ürünler geliştiren ekipler de kesinlikle bulamadı. Kendi kod tabanlarına en yakın olan geliştiriciler bunu ilk keşfedenler olacak.

Bir milyon geliştiriciye birleştirilebilir ilkel yapılar verin, en verimli iş akışlarını herhangi bir ürün ekibinin yukarıdan aşağıya tasarlayabileceğinden daha hızlı bulacaklardır.

## Dokümantasyon

cmux'u nasıl yapılandıracağınız hakkında daha fazla bilgi için, [dokümantasyonumuza gidin](https://cmux.com/docs/getting-started?utm_source=readme).

## Klavye Kısayolları

### Çalışma Alanları

| Kısayol | Eylem |
|----------|--------|
| ⌘ N | Yeni çalışma alanı |
| ⌘ 1–8 | Çalışma alanı 1–8'e atla |
| ⌘ 9 | Son çalışma alanına atla |
| ⌃ ⌘ ] | Sonraki çalışma alanı |
| ⌃ ⌘ [ | Önceki çalışma alanı |
| ⌘ ⇧ W | Çalışma alanını kapat |
| ⌘ ⇧ R | Çalışma alanını yeniden adlandır |
| ⌥ ⌘ E | Çalışma alanı açıklamasını düzenle |
| ⌘ B | Kenar çubuğunu aç/kapat |
| ⌥ ⌘ B | Sağ kenar çubuğunu aç/kapat |
| ⌘ ⇧ E | Sağ kenar çubuğu odağını aç/kapat |

### Surfaces

| Kısayol | Eylem |
|----------|--------|
| ⌘ T | Yeni surface |
| ⌘ ⇧ ] | Sonraki surface |
| ⌘ ⇧ [ | Önceki surface |
| ⌃ Tab | Sonraki surface |
| ⌃ ⇧ Tab | Önceki surface |
| ⌃ 1–8 | Surface 1–8'e atla |
| ⌃ 9 | Son surface'e atla |
| ⌘ W | Surface'i kapat |

### Bölünmüş Paneller

| Kısayol | Eylem |
|----------|--------|
| ⌘ D | Sağa böl |
| ⌘ ⇧ D | Aşağı böl |
| ⌥ ⌘ ← → ↑ ↓ | Yönlü panel odaklama |
| ⌘ ⇧ H | Odaklanan paneli yanıp söndür |

### Tarayıcı

Tarayıcı geliştirici araçları kısayolları Safari varsayılanlarını takip eder ve `Settings → Keyboard Shortcuts` bölümünden özelleştirilebilir.
⌃ P dahil komut paleti gezinme kısayolları da özelleştirilebilir ve tuş vuruşu aktif terminale ulaşacak şekilde temizlenebilir.

| Kısayol | Eylem |
|----------|--------|
| ⌘ ⇧ L | Bölmede tarayıcı aç |
| ⌘ L | Adres çubuğuna odaklan |
| ⌘ [ | Geri |
| ⌘ ] | İleri |
| ⌘ R | Sayfayı yeniden yükle |
| ⌥ ⌘ I | Geliştirici Araçlarını aç/kapat (Safari varsayılanı) |
| ⌥ ⌘ C | JavaScript Konsolunu göster (Safari varsayılanı) |

### Bildirimler

| Kısayol | Eylem |
|----------|--------|
| ⌘ I | Bildirim panelini göster |
| ⌘ ⇧ U | En son okunmamışa atla |
| ⌥ ⌘ U | Mevcut öğenin okunmamış durumunu aç/kapat |
| ⌃ ⌘ U | Mevcut öğeyi en eski okunmamış olarak işaretle ve bir sonraki okunmamışa atla |

### Bul

| Kısayol | Eylem |
|----------|--------|
| ⌘ F | Bul |
| ⌘ ⇧ F | Dizinde bul |
| ⌘ G / ⌥ ⌘ G | Sonrakini bul / Öncekini bul |
| ⌥ ⌘ ⇧ F | Arama çubuğunu gizle |
| ⌘ E | Seçimi arama için kullan |

### Terminal

| Kısayol | Eylem |
|----------|--------|
| ⌘ K | Kaydırma geçmişini temizle |
| ⌘ C | Kopyala (seçimle) |
| ⌘ V | Yapıştır |
| ⌘ + / ⌘ - | Yazı tipi boyutunu artır / azalt |
| ⌘ 0 | Yazı tipi boyutunu sıfırla |

### Pencere

| Kısayol | Eylem |
|----------|--------|
| ⌘ ⇧ N | Yeni pencere |
| ⌘ ⇧ O | Önceki oturumu yeniden aç |
| ⌘ , | Ayarlar |
| ⌘ ⇧ , | Yapılandırmayı yeniden yükle |
| ⌘ Q | Çıkış |

## Nightly Sürümler

[cmux NIGHTLY'i indir](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY, kendi bundle ID'sine sahip ayrı bir uygulamadır, bu yüzden kararlı sürümle yan yana çalışır. En son `main` commit'inden otomatik olarak derlenir ve kendi Sparkle akışı aracılığıyla otomatik güncellenir.

Nightly hatalarını [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) üzerinde veya [Discord'daki #nightly-bugs](https://discord.gg/xsgFEVrWCZ) kanalında bildirin.

## Oturum geri yükleme

cmux'tan çıktığınızda mevcut oturum kaydedilir. Yeniden başlatıldığında cmux uygulamaya ait durumu geri yükler:
- Pencere/çalışma alanı/panel düzeni
- Çalışma dizinleri
- Terminal kaydırma geçmişi (en iyi çaba)
- Tarayıcı URL'si ve gezinme geçmişi

cmux rastgele canlı işlem durumunu checkpoint etmez. tmux, vim, shell'ler ve desteklenmeyen terminal uygulamaları normal terminaller olarak yeniden açılır.

Desteklenen agent oturumları, hooks yerel bir oturum ID'si kaydettiğinde sürdürülebilir. Binary dosyasının `PATH` üzerinde olması için hooks'u agent CLI'sini kurduktan sonra kurun:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` bulabildiği desteklenen agentleri kurar ve atlanan agentler için bir özet yazdırır. Desteklenen resume entegrasyonları arasında Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory ve Qoder bulunur. Claude entegrasyonu Ayarlar'da etkinleştirildiğinde Claude Code, cmux Claude wrapper tarafından işlenir.

Gelişmiş kullanıcılar ve entegrasyonlar mevcut terminal surface'ine özel bir resume komutu bağlayabilir. Bu, tmux oturumları veya özel agent CLI'ları gibi kendi kalıcı durumuna sahip araçlar için kullanışlıdır:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Bu binding cmux surface'ine bağlı kalır. Genel CLI veya socket ile oluşturulan bindingler, otomatik resume için imzalı bir komut öneki onaylamadığınız sürece inceleme ve manuel resume için saklanır. Onaylanan önekler ayrıca, mevcut olduğunda, çalışma dizinine ve tam ortam değerlerine de bağlanır. Onayları **Settings > Terminal > Resume Commands** bölümünde gözden geçirin veya düzenleyin. cmux yalnızca güvenilir olarak işaretlediği resume bindinglerini otomatik çalıştırır, örneğin canlı processlerden algılanan tmux bindingleri veya kullanıcı tarafından onaylanan önekler. Token, parola, gizli değer ve API anahtarı gibi hassas ortam anahtarları resume binding kaydedilmeden önce atılır.

Geri yüklenen agent terminallerinin resume komutlarını otomatik çalıştırmak yerine boşta kalmasını sağlamak için **Settings > Terminal > Resume Agent Sessions on Reopen** seçeneğini kapatın veya bunu `~/.config/cmux/cmux.json` dosyasında ayarlayın:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Bu yalnızca otomatik agent resume komutlarını devre dışı bırakır. cmux yine de kaydedilmiş düzeni, çalışma dizinlerini, kaydırma geçmişini ve tarayıcı geçmişini geri yükler.

Son kaydedilen anlık görüntüyü manuel olarak yeniden uygulamanız gerekirse, şunu kullanın:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

Arka planda cmux, `~/Library/Application Support/cmux/` altında sürümlenmiş bir anlık görüntü yazar ve agent hooks oturum eşlemelerini `~/.cmuxterm/` altında yazar. Geri yükleme sırasında cmux önce düzeni yeniden oluşturur, ardından otomatik agent resume etkinleştirildiğinde desteklenen agentin yerel resume komutunu çalıştırır.

Tam kılavuzu <https://cmux.com/docs/session-restore> adresinde okuyun.

## SSS

### cmux, Ghostty ile nasıl ilişkilidir?

cmux, Ghostty'nin bir fork'u değildir. Uygulamaların web görünümleri için WebKit kullanması gibi, terminal görüntüleme için [libghostty](https://github.com/ghostty-org/ghostty)'yi bir kütüphane olarak kullanır. Ghostty bağımsız bir terminaldir; cmux, onun görüntüleme motoru üzerine inşa edilmiş farklı bir uygulamadır.

### Hangi platformları destekler?

Şimdilik yalnızca macOS. cmux, yerel bir Swift + AppKit uygulamasıdır.

### Bir iOS uygulaması var mı?

Evet, betada. iPhone'unuzu Mobile Connect penceresinden Mac'inizle eşleştirin ve telefonunuzdan terminallerinize bağlanın, isteğe bağlı terminal bildirimi iletmeyle birlikte. TestFlight'ta cmux BETA olarak sunulur. [iOS dokümantasyonuna](https://cmux.com/docs/ios) bakın.

### cmux hangi kodlama ajanlarıyla çalışır?

Hepsiyle. cmux bir terminaldir, bu yüzden bir terminalde çalışan herhangi bir ajan kutudan çıktığı gibi çalışır: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent ve komut satırından başlatabileceğiniz başka her şey.

### cmux birden fazla ajanı ve alt ajanı orkestre edebilir mi?

Evet. Bir ajan alt ajanlar veya takım arkadaşları oluşturduğunda, cmux bunları gizli arka plan işlemleri yerine yerel panellere ve bölmelere dönüştürür. [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) ve [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) çoklu model orkestrasyonunu destekler, böylece bir çalıştırmadaki her ajan görünür ve kontrol edilebilir.

### cmux'u uzak makinelerle kullanabilir miyim?

Evet. SSH üzerinden çalışma alanları açın ve uzak tmux oturumlarına bağlanın, böylece ajanlar uzak bir hostta çalışırken siz onları cmux'tan yönetebilirsiniz. [SSH ve uzaktan](https://cmux.com/docs/ssh) bölümüne bakın.

### Bildirimler nasıl çalışır?

Bir işlem dikkat istediğinde, cmux panellerin etrafında bildirim halkaları, kenar çubuğunda okunmamış rozetleri, bir bildirim popover'ı ve bir macOS masaüstü bildirimi gösterir. Bunlar standart terminal escape dizileri (OSC 9/99/777) aracılığıyla otomatik olarak tetiklenir veya [cmux CLI](https://cmux.com/docs/notifications#cli-usage) ve [agent hooks](https://cmux.com/docs/notifications#integration-examples) ile tetikleyebilirsiniz. Hooks veya OSC destekleyen herhangi bir ajan çalışır, buna Claude Code, Codex, OpenCode ve pi dahildir.

### cmux programlanabilir mi?

Evet. Her eylem cmux CLI ve bir Unix socket aracılığıyla kullanılabilir: çalışma alanları oluşturun, bölünmüş paneller açın, girdi gönderin, ekran içeriğini okuyun, ekran görüntüleri alın ve uygulama içi tarayıcıyı yönetin. [CLI referansı](https://cmux.com/docs/api) ve [tarayıcı otomasyonu](https://cmux.com/docs/browser-automation) dokümanlarına bakın.

### Yerleşik tarayıcı neler yapabilir?

cmux, terminalinizin yanında gerçek bir tarayıcı paneli bölebilir ve tamamen programlanabilir: gezinin, DOM'un anlık görüntüsünü alın, tıklayın, yazın, JavaScript çalıştırın ve aynı socket API üzerinden konsol ile ağ aktivitesini okuyun. Ajanlar bunu, cmux'tan ayrılmadan kendi web değişikliklerini doğrulamak için kullanır. [Tarayıcı otomasyonuna](https://cmux.com/docs/browser-automation) bakın.

### cmux'un yetenekleri (skills) var mı?

Evet. Yetenekler, cmux'ta çalışan herhangi bir ajana verebileceğiniz, CLI kontrolü, çalışma alanı otomasyonu, ayarlar ve tarayıcı yüzeyleri gibi şeyler için yeniden kullanılabilir iş akışlarıdır. Açık koleksiyona [cmux-skills](https://github.com/manaflow-ai/cmux-skills) adresinden göz atın veya [yetenekler dokümanlarını](https://cmux.com/docs/skills) okuyun.

### Klavye kısayollarını özelleştirebilir miyim?

Terminal tuş atamaları Ghostty yapılandırma dosyanızdan (`~/.config/ghostty/config`) okunur. cmux'a özgü kısayollar (çalışma alanları, bölmeler, tarayıcı, bildirimler) Ayarlar'da özelleştirilebilir. Tam liste için [varsayılan kısayollara](https://cmux.com/docs/keyboard-shortcuts) bakın.

### cmux'u özelleştirebilir miyim?

Evet. Terminal görüntüleme Ghostty yapılandırmanızı kullanır, böylece temalar, yazı tipleri, renkler ve imleç doğrudan taşınır. cmux'un kendi `~/.config/cmux/cmux.json` dosyasındaki ayarları kenar çubuğunu, sekme çubuğunu, bölünmüş panelleri ve davranışı kontrol eder ve her [klavye kısayolu](https://cmux.com/docs/keyboard-shortcuts) düzenlenebilir. [Yapılandırmaya](https://cmux.com/docs/configuration) bakın.

### Oturumlarım kaydediliyor mu?

Evet. cmux, yeniden başlattığınızda pencerelerinizi, çalışma alanlarınızı, panellerinizi, çalışma dizinlerinizi ve kaydırma geçmişinizi geri yükler ve bu durum yalnızca uygulamadan çıkmaktan değil, tam bir bilgisayar yeniden başlatmasından da kurtulur. Claude Code, Codex ve OpenCode gibi agent oturumları da geri gelir. [Oturum geri yüklemeye](https://cmux.com/docs/session-restore) bakın.

### tmux ile nasıl karşılaştırılır?

tmux, herhangi bir terminalin içinde çalışan bir terminal çoklayıcısıdır. cmux, bir GUI'ye sahip yerel bir macOS uygulamasıdır: dikey sekmeler, bölünmüş paneller, gömülü bir tarayıcı ve bir socket API, hepsi yerleşik, yapılandırma dosyası veya önek tuşu gerekmez. Bununla birlikte, birçok kişi cmux'u SSH ve tmux ile birlikte mutlu bir şekilde çalıştırır ve cmux, uzak tmux oturumlarınıza yerel olarak bağlanabilir ([beta](https://cmux.com/docs/remote-tmux)).

### cmux ücretsiz mi?

Evet, cmux ücretsiz kullanılır. Kaynak kodu [GitHub](https://github.com/manaflow-ai/cmux)'ta mevcuttur.

### cmux'u nasıl destekleyebilirim?

cmux ücretsiz ve açık kaynaktır ve her zaman öyle kalacaktır. Geliştirmeyi desteklemek ve cmux AI, iOS uygulaması ve Cloud VMs dahil olmak üzere sırada ne olduğuna erken erişim almak isterseniz, [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)'a göz atın.

### Bir özellik isteğim var veya bir hata buldum?

Bunu duymak istiyoruz. GitHub'da bir [issue](https://github.com/manaflow-ai/cmux/issues) veya [pull request](https://github.com/manaflow-ai/cmux/pulls) açın ya da bize [e-posta gönderin](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Yıldız Geçmişi

<a href="https://www.star-history.com/?repos=manaflow-ai%2Fcmux&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&theme=dark&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=manaflow-ai/cmux&type=date&legend=top-left&sealed_token=N5E-Mdh7zIesE2fP9_q8wEZyOg3un2Ki7u61afJnUUu6ZIUEUsrH_dsPrA8CWrw12owIEezjOyhDiXcfIEoSzAlIybOqvxTk-xCpuXbpnFk86SkJzfErObW1u0MrAuLp-_tXZDM1kAMI2jMtAeXZK3_VEe2HH9dNyhXxgMTCns6c7lMmCJ_kSIgtooYf" />
 </picture>
</a>

## Katkıda Bulunma

Katılım yolları:

- Güncellemeler için bizi X'te takip edin [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) ve [@austinywang](https://x.com/austinywang)
- [Discord](https://discord.gg/xsgFEVrWCZ)'da sohbete katılın
- [GitHub issues](https://github.com/manaflow-ai/cmux/issues) ve [discussions](https://github.com/manaflow-ai/cmux/discussions) oluşturun ve katılın
- cmux ile ne inşa ettiğinizi bize bildirin

## Topluluk

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [WhatsApp](https://chat.whatsapp.com/Fblh7FB58lOI2cx6ccdIqY?mode=gi_t)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat:</strong> Topluluğa katılmak için QR kodunu tarayın.<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="cmux topluluğuna katılmak için WeChat QR kodu" width="240" />
</p>

## Founder's Edition

cmux ücretsiz, açık kaynak ve her zaman öyle olacak. Geliştirmeyi desteklemek ve sırada ne olduğuna erken erişim almak isterseniz:

**[Founder's Edition'ı Edinin](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Öncelikli özellik istekleri/hata düzeltmeleri**
- **Erken erişim: Her çalışma alanı, sekme ve panel hakkında bağlam sağlayan cmux AI**
- **Erken erişim: Masaüstü ve telefon arasında senkronize terminallere sahip iOS uygulaması**
- **Erken erişim: Bulut VM'ler**
- **Erken erişim: Sesli mod**
- **Kişisel iMessage/WhatsApp'ım**

## Lisans

cmux, [GPL-3.0-or-later](LICENSE) kapsamında açık kaynaklıdır.

Kuruluşunuz GPL'ye uyum sağlayamıyorsa, ticari lisans mevcuttur. Ayrıntılar için [founders@manaflow.com](mailto:founders@manaflow.com) ile iletişime geçin.
