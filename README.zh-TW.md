> 此翻譯由 Claude 生成。如有改進建議，歡迎提交 PR。

<h1 align="center">cmux</h1>
<p align="center">基於 Ghostty 的 macOS 終端機，具備垂直分頁和為 AI 程式設計代理設計的通知系統</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="下載 cmux macOS 版" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux 螢幕截圖" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ 示範影片</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## 功能特色

<table>
<tr>
<td width="40%" valign="middle">
<h3>通知提示環</h3>
當程式設計代理需要您注意時，窗格會顯示藍色光環，分頁會亮起
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="通知提示環" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>通知面板</h3>
在一處檢視所有待處理通知，快速跳至最新未讀通知
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="側邊欄通知徽章" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>內建瀏覽器</h3>
在終端機旁邊分割出瀏覽器窗格，提供從 <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a> 移植的可指令化 API
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="內建瀏覽器" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>垂直 + 水平分頁</h3>
側邊欄顯示 git 分支、關聯 PR 狀態/編號、工作目錄、監聽連接埠和最新通知文字。支援水平和垂直分割。
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="垂直分頁和分割窗格" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> 為遠端機器建立工作區。瀏覽器窗格透過遠端網路路由，因此 localhost 直接可用。將圖片拖入遠端工作階段即可透過 scp 上傳。
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> 一條指令執行 Claude Code 的隊友模式。隊友以原生分割的形式產生，側邊欄顯示中繼資料和通知。無需 tmux。
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **瀏覽器匯入** — 從 Chrome、Firefox、Arc 及 20 多種瀏覽器匯入 Cookie、歷史記錄和工作階段，讓瀏覽器窗格啟動即已登入
- **自訂指令** — 在 [`cmux.json`](https://cmux.com/docs/custom-commands) 中定義專案專屬操作，透過指令面板啟動
- **可指令化** — 透過 CLI 和 socket API 建立工作區、分割窗格、傳送按鍵和自動化瀏覽器操作
- **原生 macOS 應用程式** — 使用 Swift 和 AppKit 建構，非 Electron。啟動快速，記憶體佔用低。
- **相容 Ghostty** — 讀取您現有的 `~/.config/ghostty/config` 設定檔中的主題、字型和色彩設定
- **GPU 加速** — 由 libghostty 驅動，渲染流暢
- **鍵盤快捷鍵** — 為工作區、分割、瀏覽器等提供[豐富的快捷鍵](https://cmux.com/docs/keyboard-shortcuts)
- **開放原始碼** — 免費且採用 GPL 授權

## 安裝

### DMG（推薦）

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="下載 cmux macOS 版" width="180" />
</a>

開啟 `.dmg` 檔案並將 cmux 拖曳至「應用程式」資料夾。cmux 透過 Sparkle 自動更新，您只需下載一次。

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

之後更新：

```bash
brew upgrade --cask cmux
```

首次啟動時，macOS 可能會要求您確認開啟來自已驗證開發者的應用程式。點擊**開啟**即可繼續。

## 為什麼做 cmux？

我同時執行大量 Claude Code 和 Codex 工作階段。之前我用 Ghostty 開了一堆分割窗格，依靠 macOS 原生通知來得知代理何時需要我。但 Claude Code 的通知內容總是千篇一律的「Claude is waiting for your input」，沒有任何上下文資訊，而且分頁一多，連標題都看不清了。

我試過幾個程式設計協調工具，但大多數都是 Electron/Tauri 應用程式，效能讓我不滿意。我也更喜歡終端機，因為 GUI 協調工具會把你鎖定在它們的工作流程裡。所以我用 Swift/AppKit 建構了 cmux，作為一個原生 macOS 應用程式。它使用 libghostty 進行終端機渲染，並讀取您現有的 Ghostty 設定中的主題、字型和色彩設定。

主要新增的是側邊欄和通知系統。側邊欄有垂直分頁，顯示每個工作區的 git 分支、關聯 PR 狀態/編號、工作目錄、監聽連接埠和最新通知文字。通知系統能擷取終端機序列（OSC 9/99/777），並提供 CLI（`cmux notify`），您可以將其接入 Claude Code、OpenCode 等代理的 hooks。當代理等待時，其窗格會顯示藍色光環，分頁會在側邊欄亮起，這樣我就能在多個分割窗格和分頁之間一眼看出哪個需要我。Cmd+Shift+U 可以跳至最新的未讀通知。

內建瀏覽器擁有從 [agent-browser](https://github.com/vercel-labs/agent-browser) 移植的可指令化 API。代理可以擷取無障礙樹快照、取得元素參照、執行點擊、填寫表單和執行 JS。您可以在終端機旁邊分割出瀏覽器窗格，讓 Claude Code 直接與您的開發伺服器互動。

所有操作都可以透過 CLI 和 socket API 進行指令化 — 建立工作區/分頁、分割窗格、傳送按鍵、在瀏覽器中開啟 URL。

## The Zen of cmux

cmux 不規定開發者應該如何使用工具。它是一個帶有 CLI 的終端機和瀏覽器，其餘的由你決定。

cmux 是原語，而非解決方案。它提供終端機、瀏覽器、通知、工作區、分割、分頁，以及控制這一切的 CLI。cmux 不強迫你以特定方式使用程式設計代理。你用這些原語建構什麼，完全取決於你自己。

最優秀的開發者一直在建構自己的工具。還沒有人找到與代理協作的最佳方式，那些建構封閉產品的團隊也沒有找到。最接近自己程式碼庫的開發者會最先找到答案。

給一百萬個開發者可組合的原語，他們會比任何由上而下設計的產品團隊更快地找到最高效的工作流程。

## 文件

有關 cmux 設定的更多資訊，請[前往我們的文件](https://cmux.com/docs/getting-started?utm_source=readme)。

## 鍵盤快捷鍵

### 工作區

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ N | 新增工作區 |
| ⌘ 1–8 | 跳至工作區 1–8 |
| ⌘ 9 | 跳至最後一個工作區 |
| ⌃ ⌘ ] | 下一個工作區 |
| ⌃ ⌘ [ | 上一個工作區 |
| ⌘ ⇧ W | 關閉工作區 |
| ⌘ ⇧ R | 重新命名工作區 |
| ⌥ ⌘ E | 編輯工作區描述 |
| ⌘ B | 切換側邊欄 |
| ⌥ ⌘ B | 切換右側邊欄 |
| ⌘ ⇧ E | 切換右側邊欄焦點 |

### 介面

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ T | 新增介面 |
| ⌘ ⇧ ] | 下一個介面 |
| ⌘ ⇧ [ | 上一個介面 |
| ⌃ Tab | 下一個介面 |
| ⌃ ⇧ Tab | 上一個介面 |
| ⌃ 1–8 | 跳至介面 1–8 |
| ⌃ 9 | 跳至最後一個介面 |
| ⌘ W | 關閉介面 |

### 分割窗格

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ D | 向右分割 |
| ⌘ ⇧ D | 向下分割 |
| ⌥ ⌘ ← → ↑ ↓ | 按方向切換焦點窗格 |
| ⌘ ⇧ H | 閃爍聚焦面板 |

### 瀏覽器

瀏覽器開發者工具快捷鍵遵循 Safari 預設設定，可在 `設定 → 鍵盤快捷鍵` 中自訂。
指令面板導覽快捷鍵（包括 ⌃ P）同樣可自訂，並可清除以便按鍵傳遞到使用中的終端機。

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ ⇧ L | 在分割中開啟瀏覽器 |
| ⌘ L | 聚焦網址列 |
| ⌘ [ | 上一頁 |
| ⌘ ] | 下一頁 |
| ⌘ R | 重新整理頁面 |
| ⌥ ⌘ I | 切換開發者工具（Safari 預設） |
| ⌥ ⌘ C | 顯示 JavaScript 主控台（Safari 預設） |

### 通知

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ I | 顯示通知面板 |
| ⌘ ⇧ U | 跳至最新未讀 |
| ⌥ ⌘ U | 切換目前項目的未讀狀態 |
| ⌃ ⌘ U | 將目前項目標記為最早未讀並跳至下一個最新未讀 |

### 尋找

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ F | 尋找 |
| ⌘ ⇧ F | 在目錄中尋找 |
| ⌘ G / ⌥ ⌘ G | 尋找下一個 / 上一個 |
| ⌥ ⌘ ⇧ F | 隱藏尋找列 |
| ⌘ E | 使用選取內容進行尋找 |

### 終端機

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ K | 清除回捲緩衝區 |
| ⌘ C | 複製（有選取內容時） |
| ⌘ V | 貼上 |
| ⌘ + / ⌘ - | 放大 / 縮小字型 |
| ⌘ 0 | 重置字型大小 |

### 視窗

| 快捷鍵 | 操作 |
|----------|--------|
| ⌘ ⇧ N | 新增視窗 |
| ⌘ ⇧ O | 重新開啟上一個工作階段 |
| ⌘ , | 設定 |
| ⌘ ⇧ , | 重新載入設定 |
| ⌘ Q | 結束 |

## 每夜建置

[下載 cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY 是一個擁有獨立 Bundle ID 的單獨應用程式，因此可以與穩定版並行執行。它從最新的 `main` 提交自動建置，並透過獨立的 Sparkle 更新來源自動更新。

請在 [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) 或 [Discord 的 #nightly-bugs 頻道](https://discord.gg/xsgFEVrWCZ) 上回報每夜建置的 bug。

## 工作階段還原

結束 cmux 會儲存目前的工作階段。重新啟動時，cmux 會還原應用程式管理的狀態：
- 視窗/工作區/窗格佈局
- 工作目錄
- 終端機回捲緩衝區（盡力還原）
- 瀏覽器 URL 和導覽歷史

cmux 不會為任意即時程序狀態建立檢查點。tmux、vim、shell 和不支援的終端機應用程式會作為一般終端機重新開啟。

當 hooks 儲存了原生工作階段 ID 時，受支援的 agent 工作階段可以還原。請在安裝 agent CLI 之後再安裝 hooks，以確保其二進位檔位於 `PATH` 上：

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` 會安裝它能找到的受支援 agent，並為略過的 agent 列印摘要。受支援的還原整合包括 Claude Code、Codex、Grok、OpenCode、Pi、Amp、Cursor CLI、Gemini、Rovo Dev、Copilot、CodeBuddy、Factory 和 Qoder。當在設定中啟用了 Claude 整合時，Claude Code 由 cmux Claude wrapper 處理。

進階使用者和整合可以把自訂還原指令繫結到目前的終端機 surface。這適用於 tmux 工作階段或自訂 agent CLI 等擁有持久狀態的工具：

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

這個繫結會繼續關聯到 cmux surface。透過公開 CLI 或 socket 建立的繫結會儲存以供檢查和手動還原，除非您為某個簽署指令前綴核准了自動還原。已核准的前綴還會繫結到工作目錄和確切的環境變數值（如果存在）。可在 **設定 > 終端機 > 還原指令** 中檢視或編輯核准項。cmux 只會自動執行它標記為可信的還原繫結，例如從執行中程序偵測到的 tmux 繫結或使用者核准的前綴。權杖、密碼、密鑰和 API key 等敏感環境變數鍵會在儲存還原繫結前被捨棄。

如需讓還原的 agent 終端機保持閒置，而不是自動執行其還原指令，請關閉 **設定 > 終端機 > 重新開啟時還原 Agent 工作階段**，或在 `~/.config/cmux/cmux.json` 中設定：

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

這只會停用自動的 agent 還原指令。cmux 仍會還原儲存的佈局、工作目錄、回捲緩衝區和瀏覽器歷史。

如果您需要手動重新套用上次儲存的快照，請使用：
- `檔案 > 重新開啟上一個工作階段`
- `⌘ ⇧ O`
- `cmux restore-session`

在底層，cmux 會在 `~/Library/Application Support/cmux/` 下寫入帶版本的快照，agent hooks 會在 `~/.cmuxterm/` 下寫入工作階段對應。還原時，cmux 會先重建佈局，然後在啟用了自動 agent 還原時執行受支援 agent 的原生還原指令。

完整指南請見 <https://cmux.com/docs/session-restore>。

## FAQ

### cmux 與 Ghostty 是什麼關係？

cmux 不是 Ghostty 的分支。它把 [libghostty](https://github.com/ghostty-org/ghostty) 作為函式庫用於終端機渲染，就像應用程式使用 WebKit 來呈現網頁檢視一樣。Ghostty 是一個獨立的終端機；cmux 是建構在其渲染引擎之上的另一款應用程式。

### 它支援哪些平台？

目前僅支援 macOS。cmux 是一個原生的 Swift + AppKit 應用程式。

### 有 iOS 應用程式嗎？

有，目前處於測試階段。在 Mobile Connect 視窗中將您的 iPhone 與 Mac 配對，即可從手機連接到您的終端機，並可選擇轉發終端機通知。它以 cmux BETA 的形式透過 TestFlight 發布。請參閱 [iOS 文件](https://cmux.com/docs/ios)。

### cmux 支援哪些程式設計代理？

全部支援。cmux 是一個終端機，因此任何能在終端機中執行的代理都開箱即用：Claude Code、Codex、OpenCode、Gemini CLI、Kiro、Aider、Goose、Amp、Cline、Cursor Agent，以及任何其他可從命令列啟動的工具。

### cmux 能編排多個代理和子代理嗎？

可以。當某個代理產生子代理或隊友時，cmux 會把它們變成原生窗格和分割，而不是隱藏的背景程序。它支援 [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) 和 [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) 的多模型編排，因此一次執行中的每個代理都可見、可控。

### 我可以用 cmux 操作遠端機器嗎？

可以。透過 SSH 開啟工作區並連接到遠端 tmux 工作階段，這樣代理可以在遠端主機上執行，而您從 cmux 來驅動它們。請參閱 [SSH 和遠端](https://cmux.com/docs/ssh)。

### 通知是如何運作的？

當某個程序需要關注時，cmux 會在窗格周圍顯示通知提示環、在側邊欄顯示未讀徽章、彈出通知氣泡，以及 macOS 桌面通知。這些會透過標準終端機跳脫序列（OSC 9/99/777）自動觸發，您也可以用 [cmux CLI](https://cmux.com/docs/notifications#cli-usage) 和 [agent hooks](https://cmux.com/docs/notifications#integration-examples) 來觸發它們。任何支援 hooks 或 OSC 的代理都可使用，包括 Claude Code、Codex、OpenCode 和 pi。

### cmux 可程式化嗎？

可以。每個操作都可透過 cmux CLI 和 Unix socket 使用：建立工作區、開啟分割窗格、傳送輸入、讀取螢幕內容、截圖，以及驅動內建瀏覽器。請參閱 [CLI 參考](https://cmux.com/docs/api) 和 [瀏覽器自動化](https://cmux.com/docs/browser-automation) 文件。

### 內建瀏覽器能做什麼？

cmux 可以在終端機旁邊分割出一個真正的瀏覽器窗格，並且它完全可程式化：導覽、擷取 DOM 快照、點擊、輸入、執行 JavaScript，以及透過同一套 socket API 讀取主控台和網路活動。代理用它來驗證自己做的網頁變更，而無需離開 cmux。請參閱 [瀏覽器自動化](https://cmux.com/docs/browser-automation)。

### cmux 有 skills 嗎？

有。Skills 是可重複使用的工作流程，您可以將其交給任何執行在 cmux 中的代理，用於諸如 CLI 控制、工作區自動化、設定和瀏覽器介面等任務。可在 [cmux-skills](https://github.com/manaflow-ai/cmux-skills) 瀏覽開放的合集，或閱讀 [skills 文件](https://cmux.com/docs/skills)。

### 我可以自訂鍵盤快捷鍵嗎？

終端機鍵繫結從您的 Ghostty 設定檔（`~/.config/ghostty/config`）中讀取。cmux 專屬的快捷鍵（工作區、分割、瀏覽器、通知）可在設定中自訂。完整列表請參閱 [預設快捷鍵](https://cmux.com/docs/keyboard-shortcuts)。

### 我可以自訂 cmux 嗎？

可以。終端機渲染使用您的 Ghostty 設定，因此主題、字型、色彩和游標會直接沿用。cmux 自己在 `~/.config/cmux/cmux.json` 中的設定控制側邊欄、分頁列、分割窗格和行為，並且每個[鍵盤快捷鍵](https://cmux.com/docs/keyboard-shortcuts)都可編輯。請參閱 [設定](https://cmux.com/docs/configuration)。

### 我的工作階段會被儲存嗎？

會。cmux 在重新啟動時會還原您的視窗、工作區、窗格、工作目錄和回捲緩衝區，並且這些狀態能在整機重新開機後保留，而不僅僅是結束應用程式。像 Claude Code、Codex 和 OpenCode 這樣的 agent 工作階段也會回來。請參閱 [工作階段還原](https://cmux.com/docs/session-restore)。

### 它與 tmux 相比如何？

tmux 是一個在任意終端機內執行的終端機多工器。cmux 是一個帶 GUI 的原生 macOS 應用程式：垂直分頁、分割窗格、內嵌瀏覽器和 socket API，全部內建，無需設定檔或前綴鍵。話雖如此，很多人樂於把 cmux 與 SSH 和 tmux 一起使用，而 cmux 可以原生連接到您的遠端 tmux 工作階段（[測試版](https://cmux.com/docs/remote-tmux)）。

### cmux 免費嗎？

是的，cmux 免費使用。原始碼可在 [GitHub](https://github.com/manaflow-ai/cmux) 上取得。

### 我如何支援 cmux？

cmux 免費且開放原始碼，並將一直如此。如果您想支持開發並提前體驗接下來的功能，包括 cmux AI、iOS 應用程式和 Cloud VMs，請查看 [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)。

### 我有功能請求或發現了 bug？

我們很想聽到。請在 GitHub 上提交 [issue](https://github.com/manaflow-ai/cmux/issues) 或 [pull request](https://github.com/manaflow-ai/cmux/pulls)，或者 [寄電子郵件給我們](mailto:founders@manaflow.com?subject=cmux%20feature%20request)。

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## 參與貢獻

參與方式：

- 在 X 上追蹤我們：[@manaflowai](https://x.com/manaflowai)、[@lawrencecchen](https://x.com/lawrencecchen)、[@austinywang](https://x.com/austinywang)
- 加入 [Discord](https://discord.gg/xsgFEVrWCZ) 討論
- 建立和參與 [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) 和[討論](https://github.com/manaflow-ai/cmux/discussions)
- 告訴我們您在用 cmux 建構什麼

## 社群

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux 免費、開放原始碼，並將一直如此。如果您想支持開發並提前體驗即將推出的功能：

**[取得 Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **功能請求/Bug 修復優先處理**
- **搶先體驗：為每個工作區、分頁和面板提供上下文的 cmux AI**
- **搶先體驗：桌面與手機間終端機同步的 iOS 應用程式**
- **搶先體驗：雲端虛擬機器**
- **搶先體驗：語音模式**
- **我的個人 iMessage/WhatsApp**

## 授權

cmux 以 [GPL-3.0-or-later](LICENSE) 開放原始碼。

如果您的組織無法遵守 GPL，可提供商業授權。詳情請聯絡 [founders@manaflow.com](mailto:founders@manaflow.com)。
