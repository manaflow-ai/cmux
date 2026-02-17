> Bu çeviri Claude tarafından oluşturulmuştur. İyileştirme önerileriniz varsa lütfen bir PR açın.

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | Türkçe
</p>

<h1 align="center">cmux</h1>
<p align="center">AI kodlama ajanları için dikey sekmeler ve bildirimler içeren Ghostty tabanlı macOS terminali</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS için cmux'u indir" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux ekran görüntüsü" width="900" />
</p>

## Özellikler

- **Dikey sekmeler** — Kenar çubuğu git dalını, çalışma dizinini, dinlenen portları ve en son bildirim metnini gösterir
- **Bildirim halkaları** — AI ajanları (Claude Code, OpenCode) dikkatinizi istediğinde paneller mavi bir halka alır ve sekmeler yanar
- **Bildirim paneli** — Bekleyen tüm bildirimleri tek bir yerden görün, en son okunmamışa atlayın
- **Bölünmüş paneller** — Yatay ve dikey bölmeler
- **Uygulama içi tarayıcı** — [agent-browser](https://github.com/vercel-labs/agent-browser)'dan aktarılmış betiklenebilir bir API ile terminalinizin yanında bir tarayıcı bölün
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

Ana eklemeler kenar çubuğu ve bildirim sistemi. Kenar çubuğunda her çalışma alanı için git dalını, çalışma dizinini, dinlenen portları ve en son bildirim metnini gösteren dikey sekmeler var. Bildirim sistemi terminal dizilerini (OSC 9/99/777) yakalıyor ve Claude Code, OpenCode vb. için ajan kancalarına bağlayabileceğiniz bir CLI'ye (`cmux notify`) sahip. Bir ajan beklerken paneli mavi bir halka alıyor ve sekme kenar çubuğunda yanıyor, böylece bölmeler ve sekmeler arasında hangisinin bana ihtiyacı olduğunu görebiliyorum. Cmd+Shift+U en son okunmamışa atlıyor.

Uygulama içi tarayıcının [agent-browser](https://github.com/vercel-labs/agent-browser)'dan aktarılmış betiklenebilir bir API'si var. Ajanlar erişilebilirlik ağacının anlık görüntüsünü alabilir, öğe referansları elde edebilir, tıklayabilir, formları doldurabilir ve JS çalıştırabilir. Terminalinizin yanında bir tarayıcı paneli bölebilir ve Claude Code'un geliştirme sunucunuzla doğrudan etkileşime girmesini sağlayabilirsiniz.

Her şey CLI ve socket API aracılığıyla betiklenebilir — çalışma alanları/sekmeler oluşturun, panelleri bölün, tuş vuruşları gönderin, tarayıcıda URL'ler açın.

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

| Kısayol | Eylem |
|----------|--------|
| ⌘ ⇧ L | Bölmede tarayıcı aç |
| ⌘ L | Adres çubuğuna odaklan |
| ⌘ [ | Geri |
| ⌘ ] | İleri |
| ⌘ R | Sayfayı yeniden yükle |
| ⌥ ⌘ I | Geliştirici Araçlarını aç |

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

## Lisans

Bu proje GNU Affero Genel Kamu Lisansı v3.0 veya sonrası (`AGPL-3.0-or-later`) ile lisanslanmıştır.

Tam metin için `LICENSE` dosyasına bakın.
