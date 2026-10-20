# lawmux

lawmux は [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) の個人 fork です。
cmux のターミナル部分（macOS アプリ・CLI）を、自分の環境向けに調整して使うためのリポジトリです。

- ライセンス: 本家と同じく、macOS アプリ・CLI などは GPL-3.0-or-later です（[LICENSE](LICENSE)）。
  `web/` や `workers/` などのサーバー部分は本家と同じ BUSL-1.1 のままで、lawmux では使っていません。
- 「cmux」は Manaflow, Inc. のプロダクト名です。lawmux は本家とは無関係の非公式 fork で、
  不具合を本家に報告しないでください。
- バイナリは配布していません。各自でソースからビルドしてください。

## 本家 cmux との違い

| 項目 | cmux | lawmux |
| --- | --- | --- |
| Release ビルドの Bundle ID | `com.cmuxterm.app` | `com.lawrenceturnerw.lawmux` |
| アプリの表示名 | cmux | lawmux |
| 設定ファイル | `~/.config/cmux/` | `~/.config/lawmux/` |
| 制御ソケットなどの状態 | `~/.local/state/cmux/` | `~/.local/state/lawmux/` |
| 利用状況の送信（PostHog） | あり | なし |
| クラッシュレポート（Sentry） | あり | なし |
| 自動アップデート（Sparkle） | あり | なし（`git pull` して再ビルド） |

Bundle ID・設定・ソケットが分かれているので、本家 cmux と同時にインストール・起動できます。
CLI のコマンド名は本家と同じ `cmux` のままです。

本家の設定を引き継ぎたい場合は、最初に一度だけコピーしてください。

```sh
mkdir -p ~/.config/lawmux
cp -R ~/.config/cmux/. ~/.config/lawmux/
```

## ソースからのビルド

### 必要なもの

- macOS 14 以降
- Xcode（App Store 版。Command Line Tools だけでは不可）
- Homebrew

```sh
# Xcode を有効にする
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# Ghostty のビルドには Zig 0.16 系が必要（brew の zig は 0.17 なので不可）
# Go は Release ビルドに含まれるトンネル拡張のビルドに必要（拡張自体は lawmux では動きません）
brew install zig@0.16 bun rustup go
brew link --force zig@0.16
rustup default stable   # 1.88 以上が必要。古い場合は rustup update stable
```

Xcode 26 以降では Metal コンパイラが別配布なので、初回に一度だけ入れます。

```sh
xcodebuild -downloadComponent MetalToolchain
```

### Release ビルド（通常はこちら）

```sh
git clone --recursive https://github.com/LawrenceTurnerW/lawmux.git
cd lawmux
./scripts/setup.sh
./scripts/lawmux-build-release.sh --install --open
```

`lawmux-build-release.sh` は Release 構成をビルドし、`cmux.app` を `lawmux.app` に改名して
署名を検証したうえで、`--install` なら `/Applications/lawmux.app` に置き、`--open` なら起動します。
署名はアドホック（Apple Developer 登録なし）です。自分でビルドしたアプリなので Gatekeeper の
警告は出ません。本家 cmux が起動したままでも実行できます。

更新するときは `git pull`（または `scripts/lawmux-sync-upstream.sh`）のあと、同じコマンドを
もう一度実行してください。起動中の lawmux があれば先に終了します。

### 開発用（Debug）ビルド

本家の開発フローをそのまま使えます。タグ付きビルドは Bundle ID が
`com.cmuxterm.app.debug.lawmux`、名前が「cmux DEV lawmux」になります。

```sh
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag lawmux
open "$HOME/Library/Developer/Xcode/DerivedData/cmux-lawmux/Build/Products/Debug/cmux DEV lawmux.app"
```

`reload.sh --launch` は本家チーム向けのログイン情報（`~/.secrets/cmuxterm-dev.env`）がないと
起動を拒否するので、`--launch` を付けずにビルドし、出力された `.app` を `open` で開きます。

### 使えない機能

- Cloud 関連機能（ログイン、Cloud ターミナル、TunnelExtension）は Manaflow のサーバーと
  Apple の署名を前提にしているため、lawmux では動きません。

### テストについて

本家のテストの一部は、変更前のパスや Bundle ID（`~/.local/state/cmux`、`com.cmuxterm.app` など）を
直書きしているため、lawmux では失敗します。本家の取り込み時の衝突を増やさないよう、
テスト側は意図的に直していません。lawmux では本家の CI も動かしていないので、
変更の確認はビルドと実機での動作確認で行っています。

## 本家の更新の取り込み

週に一度、GitHub Actions（`lawmux-upstream-check`）が本家の更新を確認し、
未取り込みのコミットがあれば Issue で知らせます。取り込みはローカルで行います。

```sh
./scripts/lawmux-sync-upstream.sh
```

本家から取り込んだ workflow は、同じ Actions が自動で無効にします。

### タグとバージョン

- 本家の `vX.Y.Z` タグは fork には写しません。同期スクリプトは `main` だけを取り込みます。
  本家のタグは本家のコミット（lawmux の変更なし）を指すので、lawmux のタグとしては意味がないためです。
- バージョン番号（`CFBundleShortVersionString`）は本家の `MARKETING_VERSION` をそのまま使います。
- 目印が欲しいときは、本家と衝突しない名前で `main` にタグを打ちます（例: `lawmux-v0.65.2`）。
  配布物はないので、タグに CI は要りません。
- About 画面の「ソースコード」リンクは、ビルドに埋め込まれたコミット（`Info.plist` の `CMUXCommit`）を
  指します。タグがなくても、そのビルドの正確なソースに飛びます。
