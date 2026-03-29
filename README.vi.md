<h1 align="center">cmux</h1>
<p align="center">Một terminal macOS dựa trên Ghostty với tab dọc và thông báo cho các agent lập trình AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Tải cmux cho macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | Tiếng Việt | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Ảnh chụp màn hình cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Video demo</a> · <a href="https://cmux.com/blog/zen-of-cmux">Thiền của cmux</a>
</p>

## Tính năng

<table>
<tr>
<td width="40%" valign="middle">
<h3>Vòng thông báo</h3>
Các pane có vòng xanh và tab sáng lên khi agent lập trình cần bạn chú ý
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Vòng thông báo" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Bảng thông báo</h3>
Xem tất cả thông báo đang chờ ở một nơi, nhảy đến thông báo chưa đọc mới nhất
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Huy hiệu thông báo ở sidebar" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Trình duyệt trong app</h3>
Chia đôi một trình duyệt cạnh terminal với API có thể script, chuyển từ <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Trình duyệt tích hợp" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Tab dọc + ngang</h3>
Sidebar hiển thị nhánh git, trạng thái/số PR liên kết, thư mục làm việc, các cổng đang lắng nghe, và dòng thông báo mới nhất. Chia đôi ngang và dọc.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Tab dọc và các pane chia" width="100%" />
</td>
</tr>
</table>

- **Có thể script** — CLI và socket API để tạo workspace, chia pane, gửi phím, và tự động hóa trình duyệt
- **Ứng dụng macOS gốc** — Xây bằng Swift và AppKit, không phải Electron. Khởi động nhanh, dùng ít bộ nhớ.
- **Tương thích Ghostty** — Đọc cấu hình `~/.config/ghostty/config` hiện có của bạn cho theme, font, và màu sắc
- **Tăng tốc GPU** — Được hỗ trợ bởi libghostty để render mượt

## Cài đặt

### DMG (khuyến nghị)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Tải cmux cho macOS" width="180" />
</a>

Mở file `.dmg` và kéo cmux vào thư mục Applications. cmux tự cập nhật qua Sparkle, nên bạn chỉ cần tải một lần.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Cập nhật sau này:

```bash
brew upgrade --cask cmux
```

Lần mở đầu tiên, macOS có thể yêu cầu bạn xác nhận mở app từ nhà phát triển được xác định. Nhấn **Open** để tiếp tục.

## Vì sao cmux?

Tôi chạy rất nhiều phiên Claude Code và Codex song song. Tôi từng dùng Ghostty với nhiều pane chia, và dựa vào thông báo macOS gốc để biết khi nào một agent cần tôi. Nhưng nội dung thông báo của Claude Code luôn chỉ là "Claude is waiting for your input" mà không có ngữ cảnh, và khi mở đủ nhiều tab thì tôi thậm chí không đọc được tiêu đề nữa.

Tôi đã thử vài trình điều phối lập trình nhưng phần lớn là app Electron/Tauri và hiệu năng làm tôi khó chịu. Tôi cũng thích terminal hơn vì các trình điều phối GUI buộc bạn theo workflow của họ. Vì vậy tôi xây cmux như một app macOS gốc bằng Swift/AppKit. Nó dùng libghostty để render terminal và đọc cấu hình Ghostty hiện có của bạn cho theme, font, và màu sắc.

Những bổ sung chính là sidebar và hệ thống thông báo. Sidebar có các tab dọc hiển thị nhánh git, trạng thái/số PR liên kết, thư mục làm việc, các cổng đang lắng nghe, và dòng thông báo mới nhất cho từng workspace. Hệ thống thông báo bắt các chuỗi terminal (OSC 9/99/777) và có CLI (`cmux notify`) để bạn nối vào hook của agent cho Claude Code, OpenCode, v.v. Khi một agent đang chờ, pane của nó có vòng xanh và tab sáng lên ở sidebar, nên tôi có thể biết cái nào cần tôi giữa các split và tab. Cmd+Shift+U nhảy đến thông báo chưa đọc mới nhất.

Trình duyệt trong app có API script được chuyển từ [agent-browser](https://github.com/vercel-labs/agent-browser). Agent có thể chụp cây accessibility, lấy tham chiếu phần tử, click, điền form, và chạy JS. Bạn có thể chia một pane trình duyệt cạnh terminal và để Claude Code tương tác trực tiếp với dev server của bạn.

Mọi thứ đều có thể script thông qua CLI và socket API — tạo workspace/tab, chia pane, gửi phím, mở URL trong trình duyệt.

## Thiền của cmux

cmux không áp đặt cách developer sử dụng công cụ. Nó là một terminal và trình duyệt có CLI, và phần còn lại là do bạn quyết định.

cmux là một nguyên thủy, không phải giải pháp. Nó cung cấp terminal, trình duyệt, thông báo, workspace, split, tab, và một CLI để điều khiển tất cả. cmux không ép bạn theo một cách dùng agent lập trình đầy định kiến. Bạn xây gì từ những nguyên thủy đó là của bạn.

Những developer giỏi nhất luôn tự xây công cụ của mình. Chưa ai tìm ra cách tốt nhất để làm việc với agent, và các đội ngũ xây sản phẩm đóng chắc chắn cũng chưa. Những developer gần codebase của họ nhất sẽ tìm ra trước.

Trao cho một triệu developer những nguyên thủy có thể ghép, và họ sẽ cùng nhau tìm ra workflow hiệu quả nhất nhanh hơn bất kỳ đội sản phẩm nào có thể thiết kế theo hướng top-down.

## Tài liệu

Để biết thêm về cách cấu hình cmux, [xem tài liệu của chúng tôi](https://cmux.com/docs/getting-started?utm_source=readme).

## Phím tắt

### Workspace

| Phím tắt | Hành động |
|----------|--------|
| ⌘ N | Workspace mới |
| ⌘ 1–8 | Nhảy đến workspace 1–8 |
| ⌘ 9 | Nhảy đến workspace cuối |
| ⌃ ⌘ ] | Workspace tiếp theo |
| ⌃ ⌘ [ | Workspace trước |
| ⌘ ⇧ W | Đóng workspace |
| ⌘ ⇧ R | Đổi tên workspace |
| ⌘ B | Bật/tắt sidebar |

### Surface

| Phím tắt | Hành động |
|----------|--------|
| ⌘ T | Surface mới |
| ⌘ ⇧ ] | Surface tiếp theo |
| ⌘ ⇧ [ | Surface trước |
| ⌃ Tab | Surface tiếp theo |
| ⌃ ⇧ Tab | Surface trước |
| ⌃ 1–8 | Nhảy đến surface 1–8 |
| ⌃ 9 | Nhảy đến surface cuối |
| ⌘ W | Đóng surface |

### Chia pane

| Phím tắt | Hành động |
|----------|--------|
| ⌘ D | Chia sang phải |
| ⌘ ⇧ D | Chia xuống dưới |
| ⌥ ⌘ ← → ↑ ↓ | Đổi focus pane theo hướng |
| ⌘ ⇧ H | Nhấp nháy panel đang focus |

### Trình duyệt

Phím tắt công cụ developer của trình duyệt theo mặc định Safari và có thể tùy chỉnh trong `Settings → Keyboard Shortcuts`.

| Phím tắt | Hành động |
|----------|--------|
| ⌘ ⇧ L | Mở trình duyệt trong pane chia |
| ⌘ L | Focus thanh địa chỉ |
| ⌘ [ | Quay lại |
| ⌘ ] | Tiến tới |
| ⌘ R | Tải lại trang |
| ⌥ ⌘ I | Bật/tắt Developer Tools (mặc định Safari) |
| ⌥ ⌘ C | Hiện JavaScript Console (mặc định Safari) |

### Thông báo

| Phím tắt | Hành động |
|----------|--------|
| ⌘ I | Hiện bảng thông báo |
| ⌘ ⇧ U | Nhảy đến thông báo chưa đọc mới nhất |

### Tìm kiếm

| Phím tắt | Hành động |
|----------|--------|
| ⌘ F | Tìm |
| ⌘ G / ⌘ ⇧ G | Tìm tiếp / tìm trước |
| ⌘ ⇧ F | Ẩn thanh tìm |
| ⌘ E | Dùng vùng chọn để tìm |

### Terminal

| Phím tắt | Hành động |
|----------|--------|
| ⌘ K | Xóa scrollback |
| ⌘ C | Sao chép (khi có chọn) |
| ⌘ V | Dán |
| ⌘ + / ⌘ - | Tăng / giảm cỡ chữ |
| ⌘ 0 | Đặt lại cỡ chữ |

### Cửa sổ

| Phím tắt | Hành động |
|----------|--------|
| ⌘ ⇧ N | Cửa sổ mới |
| ⌘ , | Cài đặt |
| ⌘ ⇧ , | Tải lại cấu hình |
| ⌘ Q | Thoát |

## Bản dựng Nightly

[Tải cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY là một app riêng với bundle ID riêng, nên có thể chạy song song với bản ổn định. Được build tự động từ commit `main` mới nhất và tự cập nhật qua feed Sparkle riêng.

Báo lỗi nightly trên [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) hoặc trong [#nightly-bugs trên Discord](https://discord.gg/xsgFEVrWCZ).

## Khôi phục phiên (hành vi hiện tại)

Khi mở lại, cmux hiện chỉ khôi phục bố cục app và metadata:
- Bố cục cửa sổ/workspace/pane
- Thư mục làm việc
- Scrollback của terminal (cố gắng hết mức)
- URL và lịch sử điều hướng của trình duyệt

cmux **không** khôi phục trạng thái tiến trình đang chạy bên trong terminal. Ví dụ, các phiên Claude Code/tmux/vim đang hoạt động chưa được khôi phục sau khi restart.

## Lịch sử sao

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Biểu đồ lịch sử sao" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Đóng góp

Cách tham gia:

- Theo dõi chúng tôi trên X để cập nhật [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), và [@austinywang](https://x.com/austinywang)
- Tham gia trò chuyện trên [Discord](https://discord.gg/xsgFEVrWCZ)
- Tạo và tham gia [GitHub issues](https://github.com/manaflow-ai/cmux/issues) và [discussions](https://github.com/manaflow-ai/cmux/discussions)
- Cho chúng tôi biết bạn đang xây gì với cmux

## Cộng đồng

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux miễn phí, mã nguồn mở, và sẽ luôn như vậy. Nếu bạn muốn hỗ trợ phát triển và có quyền truy cập sớm vào những thứ sắp tới:

**[Lấy Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Ưu tiên yêu cầu tính năng/sửa lỗi**
- **Truy cập sớm: cmux AI cung cấp ngữ cảnh cho mọi workspace, tab và panel**
- **Truy cập sớm: ứng dụng iOS với terminal đồng bộ giữa desktop và điện thoại**
- **Truy cập sớm: Cloud VM**
- **Truy cập sớm: Voice mode**
- **iMessage/WhatsApp cá nhân của tôi**

## Giấy phép

cmux là mã nguồn mở theo [AGPL-3.0-or-later](LICENSE).

Nếu tổ chức của bạn không thể tuân thủ AGPL, giấy phép thương mại có sẵn. Liên hệ [founders@manaflow.com](mailto:founders@manaflow.com) để biết chi tiết.
