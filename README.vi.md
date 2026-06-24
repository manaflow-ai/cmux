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
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
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
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> tạo workspace cho máy từ xa. Các pane trình duyệt định tuyến qua mạng từ xa nên localhost hoạt động bình thường. Kéo ảnh vào phiên từ xa để upload qua scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> chạy chế độ teammate của Claude Code chỉ với một lệnh. Các teammate sinh ra dưới dạng split gốc với metadata sidebar và thông báo. Không cần tmux.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Nhập trình duyệt** — Nhập cookie, lịch sử, và phiên từ Chrome, Firefox, Arc, và hơn 20 trình duyệt khác để các pane trình duyệt khởi động đã đăng nhập sẵn
- **Lệnh tùy chỉnh** — Định nghĩa các hành động riêng cho dự án trong [`cmux.json`](https://cmux.com/docs/custom-commands) và khởi chạy từ bảng lệnh
- **Có thể script** — CLI và socket API để tạo workspace, chia pane, gửi phím, và tự động hóa trình duyệt
- **Ứng dụng macOS gốc** — Xây bằng Swift và AppKit, không phải Electron. Khởi động nhanh, dùng ít bộ nhớ.
- **Tương thích Ghostty** — Đọc cấu hình `~/.config/ghostty/config` hiện có của bạn cho theme, font, và màu sắc
- **Tăng tốc GPU** — Được hỗ trợ bởi libghostty để render mượt
- **Phím tắt** — [Bộ phím tắt phong phú](https://cmux.com/docs/keyboard-shortcuts) cho workspace, chia pane, trình duyệt, và nhiều hơn nữa
- **Mã nguồn mở** — Miễn phí và cấp phép theo GPL

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
| ⌥ ⌘ E | Sửa mô tả workspace |
| ⌘ B | Bật/tắt sidebar |
| ⌥ ⌘ B | Bật/tắt sidebar bên phải |
| ⌘ ⇧ E | Bật/tắt focus sidebar bên phải |

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
Các phím tắt điều hướng bảng lệnh, bao gồm ⌃ P, cũng có thể tùy chỉnh và xóa đi để phím được gửi tới terminal đang hoạt động.

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
| ⌥ ⌘ U | Bật/tắt trạng thái chưa đọc của mục hiện tại |
| ⌃ ⌘ U | Đánh dấu mục hiện tại là chưa đọc cũ nhất và nhảy đến mục chưa đọc mới nhất tiếp theo |

### Tìm kiếm

| Phím tắt | Hành động |
|----------|--------|
| ⌘ F | Tìm |
| ⌘ ⇧ F | Tìm trong thư mục |
| ⌘ G / ⌥ ⌘ G | Tìm tiếp / tìm trước |
| ⌥ ⌘ ⇧ F | Ẩn thanh tìm |
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
| ⌘ ⇧ O | Mở lại phiên trước |
| ⌘ , | Cài đặt |
| ⌘ ⇧ , | Tải lại cấu hình |
| ⌘ Q | Thoát |

## Bản dựng Nightly

[Tải cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY là một app riêng với bundle ID riêng, nên có thể chạy song song với bản ổn định. Được build tự động từ commit `main` mới nhất và tự cập nhật qua feed Sparkle riêng.

Báo lỗi nightly trên [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) hoặc trong [#nightly-bugs trên Discord](https://discord.gg/xsgFEVrWCZ).

## Khôi phục phiên

Khi thoát, cmux lưu phiên hiện tại. Khi mở lại, cmux khôi phục trạng thái thuộc về app:
- Bố cục cửa sổ/workspace/pane
- Thư mục làm việc
- Scrollback của terminal (cố gắng hết mức)
- URL và lịch sử điều hướng của trình duyệt

cmux không checkpoint trạng thái tiến trình đang chạy bất kỳ. tmux, vim, shell và app terminal chưa hỗ trợ sẽ mở lại như terminal bình thường.

Các phiên agent được hỗ trợ có thể tiếp tục khi hooks đã lưu ID phiên gốc. Cài hooks sau khi cài CLI của agent để binary của nó nằm trên `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` cài các agent được hỗ trợ mà nó tìm thấy và in bản tóm tắt cho các agent bị bỏ qua. Các tích hợp resume được hỗ trợ gồm Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory, và Qoder. Claude Code được xử lý bởi wrapper Claude của cmux khi tích hợp Claude được bật trong Settings.

Người dùng nâng cao và tích hợp có thể gắn lệnh khôi phục tùy chỉnh vào surface terminal hiện tại. Điều này hữu ích cho công cụ có trạng thái bền riêng, như phiên tmux hoặc CLI agent tùy chỉnh:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Binding này vẫn gắn với surface của cmux. Binding tạo qua CLI công khai hoặc socket được lưu để kiểm tra và resume thủ công trừ khi bạn phê duyệt một tiền tố lệnh đã ký để tự động resume. Các tiền tố được phê duyệt cũng gắn với thư mục làm việc và giá trị môi trường chính xác, khi có. Xem hoặc sửa phê duyệt trong **Settings > Terminal > Resume Commands**. cmux chỉ tự động chạy những resume binding được đánh dấu là đáng tin cậy, ví dụ binding tmux phát hiện từ process đang chạy hoặc tiền tố được người dùng phê duyệt. Các khóa môi trường nhạy cảm như token, mật khẩu, secret và API key sẽ bị loại bỏ trước khi lưu resume binding.

Để giữ các terminal agent đã khôi phục ở trạng thái nhàn rỗi thay vì tự động chạy lệnh resume của chúng, hãy tắt **Settings > Terminal > Resume Agent Sessions on Reopen** hoặc đặt thiết lập này trong `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Điều này chỉ tắt lệnh resume tự động của agent. cmux vẫn khôi phục bố cục, thư mục làm việc, scrollback, và lịch sử trình duyệt đã lưu.

Nếu bạn cần áp dụng lại bản snapshot đã lưu gần nhất theo cách thủ công, hãy dùng:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

Bên trong, cmux ghi một snapshot có phiên bản tại `~/Library/Application Support/cmux/` và các agent hook ghi ánh xạ phiên tại `~/.cmuxterm/`. Khi khôi phục, cmux dựng lại bố cục trước, rồi chạy lệnh resume gốc của agent được hỗ trợ khi resume agent tự động được bật.

Đọc hướng dẫn đầy đủ tại <https://cmux.com/docs/session-restore>.

## FAQ

### cmux liên quan thế nào đến Ghostty?

cmux không phải là một fork của Ghostty. Nó dùng [libghostty](https://github.com/ghostty-org/ghostty) như một thư viện để render terminal, giống như cách các app dùng WebKit cho web view. Ghostty là một terminal độc lập; cmux là một app khác xây trên engine render của nó.

### Nó hỗ trợ những nền tảng nào?

Hiện tại chỉ macOS. cmux là một app gốc viết bằng Swift + AppKit.

### Có app iOS không?

Có, đang ở bản beta. Ghép iPhone với máy Mac của bạn từ cửa sổ Mobile Connect và kết nối tới các terminal từ điện thoại, có tùy chọn chuyển tiếp thông báo terminal. Nó được phát hành trên TestFlight dưới tên cmux BETA. Xem [tài liệu iOS](https://cmux.com/docs/ios).

### cmux hoạt động với những agent lập trình nào?

Tất cả. cmux là một terminal, nên bất kỳ agent nào chạy trong terminal đều dùng được ngay: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent, và bất cứ thứ gì khác bạn có thể khởi chạy từ dòng lệnh.

### cmux có thể điều phối nhiều agent và subagent không?

Có. Khi một agent sinh ra subagent hoặc teammate, cmux biến chúng thành các pane và split gốc thay vì các tiến trình nền ẩn. Nó hỗ trợ điều phối đa mô hình của [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) và [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode), nên mọi agent trong một lượt chạy đều hiển thị và điều khiển được.

### Tôi có thể dùng cmux với máy từ xa không?

Có. Mở workspace qua SSH và kết nối tới các phiên tmux từ xa, để agent chạy trên host từ xa trong khi bạn điều khiển chúng từ cmux. Xem [SSH và remote](https://cmux.com/docs/ssh).

### Thông báo hoạt động như thế nào?

Khi một tiến trình cần chú ý, cmux hiển thị vòng thông báo quanh các pane, huy hiệu chưa đọc ở sidebar, một popover thông báo, và một thông báo desktop macOS. Chúng tự động kích hoạt qua các chuỗi escape terminal tiêu chuẩn (OSC 9/99/777), hoặc bạn có thể kích hoạt chúng bằng [cmux CLI](https://cmux.com/docs/notifications#cli-usage) và [agent hooks](https://cmux.com/docs/notifications#integration-examples). Bất kỳ agent nào hỗ trợ hook hoặc OSC đều hoạt động, gồm Claude Code, Codex, OpenCode, và pi.

### cmux có thể lập trình được không?

Có. Mọi hành động đều có sẵn qua cmux CLI và một Unix socket: tạo workspace, mở pane chia, gửi input, đọc nội dung màn hình, chụp màn hình, và điều khiển trình duyệt trong app. Xem tài liệu [CLI reference](https://cmux.com/docs/api) và [browser automation](https://cmux.com/docs/browser-automation).

### Trình duyệt tích hợp làm được gì?

cmux có thể chia một pane trình duyệt thật cạnh terminal, và nó hoàn toàn lập trình được: điều hướng, chụp snapshot DOM, click, gõ, chạy JavaScript, và đọc hoạt động console và mạng qua cùng một socket API. Agent dùng nó để tự kiểm tra các thay đổi web của mình mà không rời cmux. Xem [browser automation](https://cmux.com/docs/browser-automation).

### cmux có skill không?

Có. Skill là các workflow tái sử dụng mà bạn có thể trao cho bất kỳ agent nào chạy trong cmux, cho những việc như điều khiển CLI, tự động hóa workspace, cài đặt, và surface trình duyệt. Duyệt bộ sưu tập mở tại [cmux-skills](https://github.com/manaflow-ai/cmux-skills), hoặc đọc [tài liệu skill](https://cmux.com/docs/skills).

### Tôi có thể tùy chỉnh phím tắt không?

Keybinding của terminal được đọc từ file cấu hình Ghostty của bạn (`~/.config/ghostty/config`). Các phím tắt riêng của cmux (workspace, split, trình duyệt, thông báo) có thể tùy chỉnh trong Settings. Xem [phím tắt mặc định](https://cmux.com/docs/keyboard-shortcuts) để có danh sách đầy đủ.

### Tôi có thể tùy chỉnh cmux không?

Có. Render terminal dùng cấu hình Ghostty của bạn, nên theme, font, màu sắc, và con trỏ chuyển sang trực tiếp. Cài đặt riêng của cmux trong `~/.config/cmux/cmux.json` điều khiển sidebar, thanh tab, pane chia, và hành vi, và mọi [phím tắt](https://cmux.com/docs/keyboard-shortcuts) đều chỉnh được. Xem [cấu hình](https://cmux.com/docs/configuration).

### Phiên của tôi có được lưu không?

Có. cmux khôi phục cửa sổ, workspace, pane, thư mục làm việc, và scrollback của bạn khi mở lại, và trạng thái này sống sót qua việc khởi động lại toàn bộ máy tính, không chỉ thoát app. Các phiên agent như Claude Code, Codex, và OpenCode cũng trở lại. Xem [khôi phục phiên](https://cmux.com/docs/session-restore).

### Nó so với tmux thế nào?

tmux là một bộ ghép kênh terminal chạy bên trong bất kỳ terminal nào. cmux là một app macOS gốc có GUI: tab dọc, pane chia, một trình duyệt nhúng, và một socket API, tất cả đều tích hợp sẵn, không cần file cấu hình hay phím prefix. Dù vậy, nhiều người vẫn vui vẻ chạy cmux cùng SSH và tmux, và cmux có thể kết nối tới các phiên tmux từ xa của bạn một cách gốc ([beta](https://cmux.com/docs/remote-tmux)).

### cmux có miễn phí không?

Có, cmux miễn phí để dùng. Mã nguồn có sẵn trên [GitHub](https://github.com/manaflow-ai/cmux).

### Tôi có thể hỗ trợ cmux như thế nào?

cmux miễn phí và mã nguồn mở, và sẽ luôn như vậy. Nếu bạn muốn ủng hộ việc phát triển và có quyền truy cập sớm vào những thứ sắp tới, gồm cmux AI, app iOS, và Cloud VMs, hãy xem [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Tôi có yêu cầu tính năng hoặc tìm thấy lỗi?

Chúng tôi rất muốn nghe. Mở một [issue](https://github.com/manaflow-ai/cmux/issues) hoặc [pull request](https://github.com/manaflow-ai/cmux/pulls) trên GitHub, hoặc [gửi email cho chúng tôi](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

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

cmux là mã nguồn mở theo [GPL-3.0-or-later](LICENSE).

Nếu tổ chức của bạn không thể tuân thủ GPL, giấy phép thương mại có sẵn. Liên hệ [founders@manaflow.com](mailto:founders@manaflow.com) để biết chi tiết.
