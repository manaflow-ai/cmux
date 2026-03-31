> 此翻譯由 Claude 生成。如有改進建議，歡迎提交 PR。

<h1 align="center">cmux</h1>
<p align="center">基於 Ghostty 的 macOS 終端機，具備垂直分頁和為 AI 程式設計代理設計的通知系統</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="下載 cmux macOS 版" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | 繁體中文 | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
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
當 AI 代理需要您注意時，窗格會顯示藍色光環，分頁會亮起
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="通知提示環" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>通知面板</h3>
在同一處檢視所有待處理通知，快速跳轉到最新未讀通知
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="側邊欄通知徽章" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>內建瀏覽器</h3>
在終端機旁分割出瀏覽器窗格，提供從 <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a> 移植的可腳本化 API
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="內建瀏覽器" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>垂直 + 水平分頁</h3>
側邊欄顯示 git 分支、關聯的 PR 狀態/編號、工作目錄、監聽連接埠和最新通知文字。支援水平和垂直分割。
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
<code>cmux claude-teams</code> 一條指令執行 Claude Code 的隊友模式。隊友以原生分割的形式產生，側邊欄顯示中繼資料和通知。不需要 tmux。
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **瀏覽器匯入** — 從 Chrome、Firefox、Arc 及 20 多種瀏覽器匯入 Cookie、歷史記錄和工作階段，讓瀏覽器窗格啟動即已登入
- **自訂指令** — 在 [`cmux.json`](https://cmux.com/docs/custom-commands) 中定義專案專屬動作，從指令面板啟動
- **可腳本化** — 透過 CLI 和 socket API 建立工作區、分割窗格、傳送按鍵和自動化瀏覽器操作
- **原生 macOS 應用程式** — 使用 Swift 和 AppKit 建構，非 Electron。啟動快速，記憶體佔用低。
- **相容 Ghostty** — 讀取您現有的 `~/.config/ghostty/config` 設定檔中的主題、字型和色彩設定
- **GPU 加速** — 由 libghostty 驅動，渲染流暢

## 安裝

### DMG（建議）

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="下載 cmux macOS 版" width="180" />
</a>

開啟 `.dmg` 檔案並將 cmux 拖曳到「應用程式」資料夾。cmux 透過 Sparkle 自動更新，您只需下載一次。

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

稍後更新：

```bash
brew upgrade --cask cmux
```

首次啟動時，macOS 可能會要求您確認開啟來自已識別開發者的應用程式。點擊**開啟**即可繼續。

## 為什麼做 cmux？

我同時執行大量 Claude Code 和 Codex 工作階段。之前我用 Ghostty 開了一堆分割窗格，依靠 macOS 原生通知來了解代理何時需要我。但 Claude Code 的通知內容總是千篇一律的「Claude is waiting for your input」，沒有任何上下文資訊，而且分頁一多，連標題都看不清了。

我試過幾個程式設計協調工具，但大多數都是 Electron/Tauri 應用程式，效能讓我不滿意。我也更偏好終端機，因為 GUI 協調工具會把你鎖定在它們的工作流程裡。所以我用 Swift/AppKit 建構了 cmux，作為一個原生 macOS 應用程式。它使用 libghostty 進行終端機渲染，並讀取您現有的 Ghostty 設定中的主題、字型和色彩設定。

主要新增的是側邊欄和通知系統。側邊欄有垂直分頁，顯示每個工作區的 git 分支、關聯的 PR 狀態/編號、工作目錄、監聽連接埠和最新通知文字。通知系統能擷取終端機序列（OSC 9/99/777），並提供 CLI（`cmux notify`），您可以將其接入 Claude Code、OpenCode 等代理的鉤子。當代理等待時，其窗格會顯示藍色光環，分頁會在側邊欄亮起，這樣我就能在多個分割窗格和分頁之間一眼看出哪個需要我。⌘⇧U 可以跳轉到最新的未讀通知。

內建瀏覽器擁有從 [agent-browser](https://github.com/vercel-labs/agent-browser) 移植的可腳本化 API。代理可以擷取無障礙樹快照、取得元素參考、執行點擊、填寫表單和執行 JS。您可以在終端機旁分割出瀏覽器窗格，讓 Claude Code 直接與您的開發伺服器互動。

所有操作都可以透過 CLI 和 socket API 進行腳本化 — 建立工作區/分頁、分割窗格、傳送按鍵、在瀏覽器中開啟 URL。

## The Zen of cmux

cmux 不會規定開發者如何使用工具。它是一個帶有 CLI 的終端機和瀏覽器，其餘由您決定。

cmux 是一個基礎元件，而非完整方案。它提供終端機、瀏覽器、通知、工作區、分割、分頁，以及控制一切的 CLI。cmux 不會強迫您採用特定的方式使用程式設計代理。您用這些基礎元件打造什麼，由您決定。

最好的開發者一直在打造自己的工具。沒有人知道與代理協作的最佳方式，那些打造封閉產品的團隊也一樣。最了解自己程式碼庫的開發者會最先找到答案。

給一百萬個開發者可組合的基礎元件，他們會比任何自上而下設計的產品團隊更快地集體找到最高效的工作流程。

## 文件

如需更多 cmux 設定資訊，[請前往我們的文件](https://cmux.com/docs/getting-started?utm_source=readme)。

## 鍵盤快捷鍵

### 工作區

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ N | 新建工作區 |
| ⌘ 1–8 | 跳轉到工作區 1–8 |
| ⌘ 9 | 跳轉到最後一個工作區 |
| ⌃ ⌘ ] | 下一個工作區 |
| ⌃ ⌘ [ | 上一個工作區 |
| ⌘ ⇧ W | 關閉工作區 |
| ⌘ ⇧ R | 重新命名工作區 |
| ⌘ B | 切換側邊欄 |

### 介面

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ T | 新建介面 |
| ⌘ ⇧ ] | 下一個介面 |
| ⌘ ⇧ [ | 上一個介面 |
| ⌃ Tab | 下一個介面 |
| ⌃ ⇧ Tab | 上一個介面 |
| ⌃ 1–8 | 跳轉到介面 1–8 |
| ⌃ 9 | 跳轉到最後一個介面 |
| ⌘ W | 關閉介面 |

### 分割窗格

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ D | 向右分割 |
| ⌘ ⇧ D | 向下分割 |
| ⌥ ⌘ ← → ↑ ↓ | 按方向切換焦點窗格 |
| ⌘ ⇧ H | 閃爍聚焦面板 |

### 瀏覽器

瀏覽器開發者工具快捷鍵遵循 Safari 預設設定，可在 `設定 → 鍵盤快捷鍵` 中自訂。

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ ⇧ L | 在分割中開啟瀏覽器 |
| ⌘ L | 聚焦網址列 |
| ⌘ [ | 後退 |
| ⌘ ] | 前進 |
| ⌘ R | 重新整理頁面 |
| ⌥ ⌘ I | 切換開發者工具（Safari 預設） |
| ⌥ ⌘ C | 顯示 JavaScript 主控台（Safari 預設） |

### 通知

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ I | 顯示通知面板 |
| ⌘ ⇧ U | 跳轉到最新未讀 |

### 尋找

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ F | 尋找 |
| ⌘ G / ⌘ ⇧ G | 尋找下一個 / 上一個 |
| ⌘ ⇧ F | 隱藏尋找列 |
| ⌘ E | 使用選取內容進行尋找 |

### 終端機

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ K | 清除捲動緩衝區 |
| ⌘ C | 複製（有選取內容時） |
| ⌘ V | 貼上 |
| ⌘ + / ⌘ - | 增大 / 縮小字型 |
| ⌘ 0 | 重設字型大小 |

### 視窗

| 快捷鍵 | 動作 |
|----------|--------|
| ⌘ ⇧ N | 新建視窗 |
| ⌘ , | 設定 |
| ⌘ ⇧ , | 重新載入設定 |
| ⌘ Q | 結束 |

## 每夜建構

[下載 cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY 是一個獨立的應用程式，擁有自己的 bundle ID，因此可以與穩定版並行執行。每次從最新的 `main` 提交自動建構，並透過自己的 Sparkle 來源自動更新。

## 工作階段還原（目前行為）

重新啟動時，cmux 目前僅還原應用程式佈局和中繼資料：
- 視窗/工作區/窗格佈局
- 工作目錄
- 終端機捲動緩衝區（盡力而為）
- 瀏覽器 URL 和瀏覽歷程

cmux **不會**還原終端機應用程式內的即時程序狀態。例如，活躍的 Claude Code/tmux/vim 工作階段在重新啟動後尚無法恢復。

## Star 歷史

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## 參與貢獻

參與方式：

- 在 X 上追蹤我們獲取最新動態 [@manaflowai](https://x.com/manaflowai)、[@lawrencecchen](https://x.com/lawrencecchen) 和 [@austinywang](https://x.com/austinywang)
- 加入 [Discord](https://discord.gg/xsgFEVrWCZ) 上的討論
- 建立和參與 [GitHub issues](https://github.com/manaflow-ai/cmux/issues) 和 [discussions](https://github.com/manaflow-ai/cmux/discussions)
- 讓我們知道您正在用 cmux 打造什麼

## 社群

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## 創始版

cmux 免費、開源，且將永遠如此。如果您想支持開發並提前體驗即將推出的功能：

**[取得創始版](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **優先處理的功能請求/錯誤修復**
- **搶先體驗：cmux AI 為您提供每個工作區、分頁和面板的上下文資訊**
- **搶先體驗：iOS 應用程式，終端機在桌面和手機之間同步**
- **搶先體驗：雲端虛擬機**
- **搶先體驗：語音模式**
- **我的個人 iMessage/WhatsApp**

## 授權條款

cmux 以 [GPL-3.0-or-later](LICENSE) 開源。

如果您的組織無法遵守 GPL，可提供商業授權。詳情請聯繫 [founders@manaflow.com](mailto:founders@manaflow.com)。
