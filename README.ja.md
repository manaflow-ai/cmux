> この翻訳は Claude によって生成されました。改善の提案がある場合は、PR を作成してください。

<h1 align="center">cmux</h1>
<p align="center">AIコーディングエージェント向けの縦タブと通知機能を備えたGhosttyベースのmacOSターミナル</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS版cmuxをダウンロード" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | 日本語 | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <strong>WeChat:</strong> QRコードをスキャンしてコミュニティに参加してください。<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="cmuxコミュニティに参加するためのWeChat QRコード" width="240" />
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmuxスクリーンショット" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ デモ動画</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## 機能

<table>
<tr>
<td width="40%" valign="middle">
<h3>通知リング</h3>
コーディングエージェントがあなたの注意を必要とするとき、ペインに青いリングが表示され、タブが点灯します
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="通知リング" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>通知パネル</h3>
保留中のすべての通知を一か所で確認、最新の未読にジャンプ
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="サイドバー通知バッジ" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>アプリ内ブラウザ</h3>
<a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>から移植されたスクリプタブルなAPIで、ターミナルの横にブラウザを分割表示
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="内蔵ブラウザ" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>縦タブ + 横タブ</h3>
サイドバーにgitブランチ、リンクされたPRのステータス/番号、作業ディレクトリ、リッスン中のポート、最新の通知テキストを表示。水平・垂直に分割可能。
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="縦タブと分割ペイン" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> でリモートマシン用のワークスペースを作成。ブラウザペインはリモートネットワーク経由でルーティングされるため、localhostがそのまま動作します。リモートセッションに画像をドラッグするとscpでアップロードされます。
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> でClaude Codeのチームメイトモードをワンコマンドで実行。チームメイトはネイティブ分割として生成され、サイドバーのメタデータと通知が表示されます。tmuxは不要です。
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **ブラウザインポート** — Chrome、Firefox、Arc、その他20以上のブラウザからCookie、履歴、セッションをインポートして、ブラウザペインを認証済みの状態で開始
- **カスタムコマンド** — [`cmux.json`](https://cmux.com/docs/custom-commands)でプロジェクト固有のアクションを定義し、コマンドパレットから実行
- **スクリプタブル** — CLIとsocket APIでワークスペースの作成、ペインの分割、キーストロークの送信、ブラウザの自動化が可能
- **ネイティブmacOSアプリ** — SwiftとAppKitで構築、Electronではありません。高速起動、低メモリ消費。
- **Ghostty互換** — 既存の`~/.config/ghostty/config`からテーマ、フォント、カラーを読み込み
- **GPU高速化** — libghosttyによるスムーズなレンダリング
- **キーボードショートカット** — ワークスペース、分割、ブラウザなどのための[豊富なショートカット](https://cmux.com/docs/keyboard-shortcuts)
- **オープンソース** — 無料、GPLライセンス

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

主な追加機能はサイドバーと通知システムです。サイドバーには、各ワークスペースのgitブランチ、リンクされたPRのステータス/番号、作業ディレクトリ、リッスン中のポート、最新の通知テキストを表示する縦タブがあります。通知システムはターミナルシーケンス（OSC 9/99/777）を検出し、Claude Code、OpenCodeなどのエージェントフックに接続できるCLI（`cmux notify`）を備えています。エージェントが待機中のとき、そのペインに青いリングが表示され、サイドバーのタブが点灯するので、分割やタブをまたいでどれが私を必要としているかがわかります。Cmd+Shift+Uで最新の未読にジャンプします。

アプリ内ブラウザには[agent-browser](https://github.com/vercel-labs/agent-browser)から移植されたスクリプタブルなAPIがあります。エージェントはアクセシビリティツリーのスナップショットを取得し、要素参照を取得し、クリック、フォーム入力、JSの評価が可能です。ターミナルの横にブラウザペインを分割し、Claude Codeに開発サーバーと直接やり取りさせることができます。

すべてがCLIとsocket APIを通じてスクリプタブルです — ワークスペース/タブの作成、ペインの分割、キーストロークの送信、ブラウザでのURL表示。

## The Zen of cmux

cmuxは開発者のツールの使い方を規定しません。ターミナルとブラウザにCLIがあり、あとはあなた次第です。

cmuxはソリューションではなくプリミティブです。ターミナル、ブラウザ、通知、ワークスペース、分割、タブ、そしてそのすべてを制御するCLIを提供します。cmuxはコーディングエージェントの使い方を強制しません。プリミティブで何を構築するかはあなた次第です。

優れた開発者は常に自分のツールを構築してきました。エージェントとの最適な作業方法はまだ誰も見つけていませんし、クローズドな製品を作っているチームも見つけていません。自分のコードベースに最も近い開発者が最初に見つけるでしょう。

100万人の開発者にコンポーザブルなプリミティブを与えれば、どんなプロダクトチームがトップダウンで設計するよりも速く、最も効率的なワークフローを集合的に見つけ出すでしょう。

## ドキュメント

cmuxの設定方法の詳細は、[ドキュメントをご覧ください](https://cmux.com/docs/getting-started?utm_source=readme)。

## キーボードショートカット

### ワークスペース

| ショートカット | アクション |
|----------|--------|
| ⌘ N | 新規ワークスペース |
| ⌘ 1–8 | ワークスペース1–8にジャンプ |
| ⌘ 9 | 最後のワークスペースにジャンプ |
| ⌃ ⌘ ] | 次のワークスペース |
| ⌃ ⌘ [ | 前のワークスペース |
| ⌘ ⇧ W | ワークスペースを閉じる |
| ⌘ ⇧ R | ワークスペースの名前を変更 |
| ⌥ ⌘ E | ワークスペースの説明を編集 |
| ⌘ B | サイドバーの表示切替 |
| ⌥ ⌘ B | 右サイドバーの表示切替 |
| ⌘ ⇧ E | 右サイドバーのフォーカス切替 |

### サーフェス

| ショートカット | アクション |
|----------|--------|
| ⌘ T | 新規サーフェス |
| ⌘ ⇧ ] | 次のサーフェス |
| ⌘ ⇧ [ | 前のサーフェス |
| ⌃ Tab | 次のサーフェス |
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
| ⌘ ⇧ H | フォーカス中のパネルを点滅 |

### ブラウザ

ブラウザの開発者ツールのショートカットはSafariのデフォルトに従い、`設定 → キーボードショートカット`でカスタマイズできます。
⌃ P を含むコマンドパレットのナビゲーションショートカットもカスタマイズ可能で、クリアしてキー入力をアクティブなターミナルに届かせることもできます。

| ショートカット | アクション |
|----------|--------|
| ⌘ ⇧ L | 分割でブラウザを開く |
| ⌘ L | アドレスバーにフォーカス |
| ⌘ [ | 戻る |
| ⌘ ] | 進む |
| ⌘ R | ページを再読み込み |
| ⌥ ⌘ I | 開発者ツールの表示切替（Safariデフォルト） |
| ⌥ ⌘ C | JavaScriptコンソールを表示（Safariデフォルト） |

### 通知

| ショートカット | アクション |
|----------|--------|
| ⌘ I | 通知パネルを表示 |
| ⌘ ⇧ U | 最新の未読にジャンプ |
| ⌥ ⌘ U | 現在の項目の未読状態を切替 |
| ⌃ ⌘ U | 現在の項目を最も古い未読としてマークし、次の最新の未読にジャンプ |

### 検索

| ショートカット | アクション |
|----------|--------|
| ⌘ F | 検索 |
| ⌘ ⇧ F | ディレクトリ内を検索 |
| ⌘ G / ⌥ ⌘ G | 次を検索 / 前を検索 |
| ⌥ ⌘ ⇧ F | 検索バーを非表示 |
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
| ⌘ ⇧ O | 前のセッションを再度開く |
| ⌘ , | 設定 |
| ⌘ ⇧ , | 設定を再読み込み |
| ⌘ Q | 終了 |

## ナイトリービルド

[cmux NIGHTLYをダウンロード](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLYは独自のバンドルIDを持つ別のアプリなので、安定版と並行して実行できます。最新の`main`コミットから自動的にビルドされ、独自のSparkleフィード経由で自動更新されます。

ナイトリーのバグは[GitHub Issues](https://github.com/manaflow-ai/cmux/issues)または[Discordの#nightly-bugs](https://discord.gg/xsgFEVrWCZ)で報告してください。

## セッション復元

終了すると、cmuxは現在のセッションを保存します。再起動時にcmuxはアプリが管理する状態を復元します：
- ウィンドウ/ワークスペース/ペインのレイアウト
- 作業ディレクトリ
- ターミナルのスクロールバック（ベストエフォート）
- ブラウザのURLとナビゲーション履歴

cmuxは任意のライブプロセス状態をチェックポイントしません。tmux、vim、シェル、未対応のターミナルアプリは通常のターミナルとして再度開きます。

対応エージェントのセッションは、フックがネイティブセッションIDを保存している場合に復元できます。エージェントのバイナリが`PATH`に乗るよう、エージェントCLIをインストールした後にフックをインストールしてください：

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup`は見つかった対応エージェントをインストールし、スキップしたエージェントのサマリーを表示します。対応する復元連携には、Claude Code、Codex、Grok、OpenCode、Pi、Amp、Cursor CLI、Gemini、Rovo Dev、Copilot、CodeBuddy、Factory、Qoderが含まれます。Claude Codeは、設定でClaude連携が有効な場合、cmuxのClaudeラッパーが処理します。

上級ユーザーや連携機能は、現在のターミナルサーフェスにカスタム復元コマンドを紐づけられます。tmuxセッションやカスタムエージェントCLIのように、独自の永続状態を持つツールに使います：

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

この紐づけはcmuxサーフェスに保存され続けます。公開CLIやsocketで作成された紐づけは、署名済みのコマンドプレフィックスを自動復元用に承認しない限り、確認と手動復元用に保存されます。承認済みプレフィックスは、存在する場合、作業ディレクトリと正確な環境変数の値にも紐づけられます。承認の確認や編集は**設定 > ターミナル > 復元コマンド**で行えます。cmuxが自動実行するのは、実行中プロセスから検出したtmux紐づけやユーザーが承認したプレフィックスなど、信頼済みとして扱う復元紐づけだけです。トークン、パスワード、シークレット、APIキーなどの機密環境変数キーは、復元紐づけを保存する前に破棄されます。

復元されたエージェントターミナルの復元コマンドを自動実行せずアイドル状態にしておきたい場合は、**設定 > ターミナル > 再オープン時にエージェントセッションを復元**をオフにするか、`~/.config/cmux/cmux.json`に次を設定してください：

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

これはエージェントの自動復元コマンドのみを無効にします。cmuxは引き続き、保存されたレイアウト、作業ディレクトリ、スクロールバック、ブラウザ履歴を復元します。

最後に保存したスナップショットを手動で再適用する必要がある場合は、次を使用してください：
- `ファイル > 前のセッションを再度開く`
- `⌘ ⇧ O`
- `cmux restore-session`

内部的には、cmuxは`~/Library/Application Support/cmux/`の下にバージョン管理されたスナップショットを書き込み、エージェントフックは`~/.cmuxterm/`の下にセッションマッピングを書き込みます。復元時、cmuxはまずレイアウトを再構築し、その後、自動エージェント復元が有効な場合に対応エージェントのネイティブ復元コマンドを実行します。

完全なガイドは<https://cmux.com/docs/session-restore>でご覧ください。

## FAQ

### cmuxはGhosttyとどう関係していますか？

cmuxはGhosttyのフォークではありません。アプリがWebビューにWebKitを使うのと同じように、ターミナルレンダリングのライブラリとして[libghostty](https://github.com/ghostty-org/ghostty)を使用しています。Ghosttyはスタンドアロンのターミナルで、cmuxはそのレンダリングエンジンの上に構築された別のアプリです。

### どのプラットフォームに対応していますか？

今のところmacOSのみです。cmuxはネイティブのSwift + AppKitアプリです。

### iOSアプリはありますか？

はい、ベータ版があります。Mobile ConnectウィンドウからiPhoneをMacとペアリングし、スマホからターミナルにアタッチできます。ターミナル通知の転送もオプションで可能です。TestFlightでcmux BETAとして配信されています。[iOSドキュメント](https://cmux.com/docs/ios)をご覧ください。

### cmuxはどのコーディングエージェントで動作しますか？

すべてです。cmuxはターミナルなので、ターミナルで動くエージェントはそのまま動作します：Claude Code、Codex、OpenCode、Gemini CLI、Kiro、Aider、Goose、Amp、Cline、Cursor Agent、そしてコマンドラインから起動できるものは何でも。

### cmuxは複数のエージェントやサブエージェントをオーケストレーションできますか？

はい。エージェントがサブエージェントやチームメイトを生成すると、cmuxはそれらを隠れたバックグラウンドプロセスではなくネイティブのペインや分割に変えます。[Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams)や[oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode)のマルチモデルオーケストレーションに対応しているので、実行中のすべてのエージェントが可視化され、制御可能です。

### リモートマシンでcmuxを使えますか？

はい。SSHでワークスペースを開き、リモートのtmuxセッションにアタッチできるので、リモートホストでエージェントを実行しながらcmuxから操作できます。[SSHとリモート](https://cmux.com/docs/ssh)をご覧ください。

### 通知はどのように機能しますか？

プロセスが注意を必要とするとき、cmuxはペイン周りの通知リング、サイドバーの未読バッジ、通知ポップオーバー、macOSのデスクトップ通知を表示します。これらは標準的なターミナルエスケープシーケンス（OSC 9/99/777）を介して自動的に発火するほか、[cmux CLI](https://cmux.com/docs/notifications#cli-usage)や[エージェントフック](https://cmux.com/docs/notifications#integration-examples)でトリガーすることもできます。Claude Code、Codex、OpenCode、piを含め、フックやOSCに対応するエージェントは何でも動作します。

### cmuxはプログラマブルですか？

はい。すべてのアクションがcmux CLIとUnixソケットを通じて利用できます：ワークスペースの作成、分割ペインのオープン、入力の送信、画面内容の読み取り、スクリーンショットの取得、そしてアプリ内ブラウザの操作。[CLIリファレンス](https://cmux.com/docs/api)と[ブラウザ自動化](https://cmux.com/docs/browser-automation)のドキュメントをご覧ください。

### 内蔵ブラウザで何ができますか？

cmuxはターミナルの横に本物のブラウザペインを分割でき、完全にプログラマブルです：ナビゲート、DOMのスナップショット、クリック、入力、JavaScriptの評価、そして同じソケットAPIでコンソールとネットワークアクティビティの読み取り。エージェントはこれを使って、cmuxを離れることなく自分のWeb変更を検証します。[ブラウザ自動化](https://cmux.com/docs/browser-automation)をご覧ください。

### cmuxにはスキルがありますか？

はい。スキルは、CLI制御、ワークスペース自動化、設定、ブラウザサーフェスなどのために、cmuxで動くあらゆるエージェントに与えられる再利用可能なワークフローです。オープンなコレクションは[cmux-skills](https://github.com/manaflow-ai/cmux-skills)で閲覧するか、[スキルのドキュメント](https://cmux.com/docs/skills)をご覧ください。

### キーボードショートカットをカスタマイズできますか？

ターミナルのキーバインドはGhostty設定ファイル（`~/.config/ghostty/config`）から読み込まれます。cmux固有のショートカット（ワークスペース、分割、ブラウザ、通知）は設定でカスタマイズできます。全リストは[デフォルトショートカット](https://cmux.com/docs/keyboard-shortcuts)をご覧ください。

### cmuxをカスタマイズできますか？

はい。ターミナルレンダリングはGhostty設定を使うので、テーマ、フォント、カラー、カーソルがそのまま引き継がれます。`~/.config/cmux/cmux.json`にあるcmux独自の設定でサイドバー、タブバー、分割ペイン、挙動を制御でき、すべての[キーボードショートカット](https://cmux.com/docs/keyboard-shortcuts)が編集可能です。[設定](https://cmux.com/docs/configuration)をご覧ください。

### セッションは保存されますか？

はい。cmuxは再起動時にウィンドウ、ワークスペース、ペイン、作業ディレクトリ、スクロールバックを復元し、その状態はアプリを終了しただけでなくコンピューターの完全な再起動でも維持されます。Claude Code、Codex、OpenCodeなどのエージェントセッションも復帰します。[セッション復元](https://cmux.com/docs/session-restore)をご覧ください。

### tmuxと比べてどうですか？

tmuxは任意のターミナル内で動くターミナルマルチプレクサです。cmuxはGUIを備えたネイティブmacOSアプリで、縦タブ、分割ペイン、組み込みブラウザ、ソケットAPIがすべて内蔵されており、設定ファイルやプレフィックスキーは不要です。とはいえ、多くの人がcmuxをSSHやtmuxと一緒に問題なく使っており、cmuxはリモートのtmuxセッションにネイティブでアタッチできます（[ベータ](https://cmux.com/docs/remote-tmux)）。

### cmuxは無料ですか？

はい、cmuxは無料で使えます。ソースコードは[GitHub](https://github.com/manaflow-ai/cmux)で公開されています。

### cmuxをどうやって支援できますか？

cmuxは無料でオープンソースであり、今後もそうあり続けます。開発を後押しし、cmux AI、iOSアプリ、Cloud VMsなど次に来るものへの早期アクセスを得たい方は、[cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)をご覧ください。

### 機能リクエストがある、またはバグを見つけました？

ぜひお聞かせください。GitHubで[issue](https://github.com/manaflow-ai/cmux/issues)や[プルリクエスト](https://github.com/manaflow-ai/cmux/pulls)を開くか、[メールでご連絡ください](mailto:founders@manaflow.com?subject=cmux%20feature%20request)。

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## コントリビューション

参加方法：

- Xでフォロー：[@manaflowai](https://x.com/manaflowai)、[@lawrencecchen](https://x.com/lawrencecchen)、[@austinywang](https://x.com/austinywang)
- [Discord](https://discord.gg/xsgFEVrWCZ)で会話に参加
- [GitHubのIssues](https://github.com/manaflow-ai/cmux/issues)や[ディスカッション](https://github.com/manaflow-ai/cmux/discussions)に参加
- cmuxで何を構築しているか教えてください

## コミュニティ

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmuxは無料でオープンソースであり、今後もそうあり続けます。開発をサポートし、次に来る機能への早期アクセスを得たい方へ：

**[Founder's Editionを入手](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **機能リクエスト/バグ修正の優先対応**
- **早期アクセス：すべてのワークスペース、タブ、パネルのコンテキストを提供するcmux AI**
- **早期アクセス：デスクトップと携帯電話間でターミナルを同期するiOSアプリ**
- **早期アクセス：クラウドVM**
- **早期アクセス：ボイスモード**
- **私の個人的なiMessage/WhatsApp**

## ライセンス

cmuxは[GPL-3.0-or-later](LICENSE)の下でオープンソースです。

GPLに準拠できない組織向けに、商用ライセンスもご用意しています。詳細は[founders@manaflow.com](mailto:founders@manaflow.com)までお問い合わせください。
