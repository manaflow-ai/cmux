> この翻訳は Claude によって生成されました。改善の提案がある場合は、PR を作成してください。

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | 日本語 | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a>
</p>

<h1 align="center">cmux</h1>
<p align="center">AIコーディングエージェント向けの縦タブと通知機能を備えたGhosttyベースのmacOSターミナル</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS版cmuxをダウンロード" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmuxスクリーンショット" width="900" />
</p>

## 機能

- **縦タブ** — サイドバーにgitブランチ、作業ディレクトリ、リッスン中のポート、最新の通知テキストを表示
- **通知リング** — AIエージェント（Claude Code、OpenCode）があなたの注意を必要とするとき、ペインに青いリングが表示され、タブが点灯
- **通知パネル** — 保留中のすべての通知を一か所で確認、最新の未読にジャンプ
- **分割ペイン** — 水平・垂直分割
- **アプリ内ブラウザ** — [agent-browser](https://github.com/vercel-labs/agent-browser)から移植されたスクリプタブルなAPIで、ターミナルの横にブラウザを分割表示
- **スクリプタブル** — CLIとsocket APIでワークスペースの作成、ペインの分割、キーストロークの送信、ブラウザの自動化が可能
- **ネイティブmacOSアプリ** — SwiftとAppKitで構築、Electronではありません。高速起動、低メモリ消費。
- **Ghostty互換** — 既存の`~/.config/ghostty/config`からテーマ、フォント、カラーを読み込み
- **GPU高速化** — libghosttyによるスムーズなレンダリング

## インストール

### DMG（推奨）

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="macOS版cmuxをダウンロード" width="180" />
</a>

`.dmg`ファイルを開き、cmuxをアプリケーションフォルダにドラッグしてください。cmuxはSparkle経由で自動更新されるため、ダウンロードは一度だけで済みます。

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

後で更新する場合：

```bash
brew upgrade --cask cmux
```

初回起動時、macOSが確認済みの開発者からのアプリを開くことの確認を求める場合があります。**開く**をクリックして続行してください。

## なぜcmux？

私はClaude CodeとCodexのセッションを多数並列で実行しています。Ghosttyで大量の分割ペインを使い、エージェントが私を必要としているときを知るためにmacOSのネイティブ通知に頼っていました。しかし、Claude Codeの通知本文はいつも「Claude is waiting for your input」というコンテキストのないものばかりで、タブを十分に開くとタイトルすら読めなくなっていました。

いくつかのコーディングオーケストレーターを試しましたが、そのほとんどがElectron/Tauriアプリで、パフォーマンスが気になりました。また、GUIオーケストレーターはそのワークフローに縛られるため、単純にターミナルのほうが好みです。そこで、cmuxをSwift/AppKitのネイティブmacOSアプリとして構築しました。ターミナルレンダリングにはlibghosttyを使用し、テーマ、フォント、カラーは既存のGhostty設定を読み込みます。

主な追加機能はサイドバーと通知システムです。サイドバーには、各ワークスペースのgitブランチ、作業ディレクトリ、リッスン中のポート、最新の通知テキストを表示する縦タブがあります。通知システムはターミナルシーケンス（OSC 9/99/777）を検出し、Claude Code、OpenCodeなどのエージェントフックに接続できるCLI（`cmux notify`）を備えています。エージェントが待機中のとき、そのペインに青いリングが表示され、サイドバーのタブが点灯するので、分割やタブをまたいでどれが私を必要としているかがわかります。Cmd+Shift+Uで最新の未読にジャンプします。

アプリ内ブラウザには[agent-browser](https://github.com/vercel-labs/agent-browser)から移植されたスクリプタブルなAPIがあります。エージェントはアクセシビリティツリーのスナップショットを取得し、要素参照を取得し、クリック、フォーム入力、JSの評価が可能です。ターミナルの横にブラウザペインを分割し、Claude Codeに開発サーバーと直接やり取りさせることができます。

すべてがCLIとsocket APIを通じてスクリプタブルです — ワークスペース/タブの作成、ペインの分割、キーストロークの送信、ブラウザでのURL表示。

## キーボードショートカット

### ワークスペース

| ショートカット | アクション |
|----------|--------|
| ⌘ N | 新規ワークスペース |
| ⌘ 1–8 | ワークスペース1–8にジャンプ |
| ⌘ 9 | 最後のワークスペースにジャンプ |
| ⌘ ⇧ W | ワークスペースを閉じる |

### サーフェス

| ショートカット | アクション |
|----------|--------|
| ⌘ T | 新規サーフェス |
| ⌘ ⇧ [ | 前のサーフェス |
| ⌃ ⇧ Tab | 前のサーフェス |
| ⌃ 1–8 | サーフェス1–8にジャンプ |
| ⌃ 9 | 最後のサーフェスにジャンプ |
| ⌘ W | サーフェスを閉じる |

### 分割ペイン

| ショートカット | アクション |
|----------|--------|
| ⌘ D | 右に分割 |
| ⌘ ⇧ D | 下に分割 |
| ⌥ ⌘ ← → ↑ ↓ | 方向でペインにフォーカス |

### ブラウザ

| ショートカット | アクション |
|----------|--------|
| ⌘ ⇧ B | 分割でブラウザを開く |
| ⌘ L | アドレスバーにフォーカス |
| ⌘ ] | 進む |
| ⌘ R | ページを再読み込み |
| ⌥ ⌘ I | 開発者ツールを開く |

### 通知

| ショートカット | アクション |
|----------|--------|
| ⌘ ⇧ I | 通知パネルを表示 |
| ⌘ ⇧ U | 最新の未読にジャンプ |

### 検索

| ショートカット | アクション |
|----------|--------|
| ⌘ F | 検索 |
| ⌘ G / ⌘ ⇧ G | 次を検索 / 前を検索 |
| ⌘ ⇧ F | 検索バーを非表示 |
| ⌘ E | 選択範囲で検索 |

### ターミナル

| ショートカット | アクション |
|----------|--------|
| ⌘ K | スクロールバックをクリア |
| ⌘ C | コピー（選択時） |
| ⌘ V | ペースト |
| ⌘ + / ⌘ - | フォントサイズを拡大 / 縮小 |
| ⌘ 0 | フォントサイズをリセット |

### ウィンドウ

| ショートカット | アクション |
|----------|--------|
| ⌘ ⇧ N | 新規ウィンドウ |
| ⌘ , | 設定 |
| ⌘ ⇧ R | 設定を再読み込み |
| ⌘ Q | 終了 |

## ライセンス

このプロジェクトはGNU Affero General Public License v3.0以降（`AGPL-3.0-or-later`）の下でライセンスされています。

全文は`LICENSE`をご覧ください。
