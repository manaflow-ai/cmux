> Bu çeviri Claude tarafından oluşturulmuştur. İyileştirme önerileriniz varsa lütfen bir PR açın.

<h1 align="center">cmux</h1>
<p align="center">AI kodlama ajanları için dikey sekmeler ve bildirimler içeren Ghostty tabanlı macOS terminali</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS için cmux'u indir" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | Türkçe | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
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
| ⌘ B | Kenar çubuğunu aç/kapat |

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

### Bul

| Kısayol | Eylem |
|----------|--------|
| ⌘ F | Bul |
| ⌘ G / ⌘ ⇧ G | Sonrakini bul / Öncekini bul |
| ⌘ ⇧ F | Arama çubuğunu gizle |
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
| ⌘ , | Ayarlar |
| ⌘ ⇧ , | Yapılandırmayı yeniden yükle |
| ⌘ Q | Çıkış |

## Nightly Sürümler

[cmux NIGHTLY'i indir](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY, kendi bundle ID'sine sahip ayrı bir uygulamadır, bu yüzden kararlı sürümle yan yana çalışır. En son `main` commit'inden otomatik olarak derlenir ve kendi Sparkle akışı aracılığıyla otomatik güncellenir.

## Oturum geri yükleme (mevcut davranış)

Yeniden başlatıldığında, cmux şu anda yalnızca uygulama düzenini ve meta verileri geri yükler:
- Pencere/çalışma alanı/panel düzeni
- Çalışma dizinleri
- Terminal kaydırma geçmişi (en iyi çaba)
- Tarayıcı URL'si ve gezinme geçmişi

cmux, terminal uygulamaları içindeki canlı işlem durumunu geri **yüklemez**. Örneğin, aktif Claude Code/tmux/vim oturumları yeniden başlatma sonrasında henüz devam ettirilmez.

## Yıldız Geçmişi

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
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
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

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
