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
brew install zig@0.16 bun rustup
brew link --force zig@0.16
rustup default stable
```

### ビルドと起動

```sh
git clone --recursive https://github.com/LawrenceTurnerW/lawmux.git
cd lawmux
./scripts/setup.sh
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag lawmux --launch
```

`reload.sh` は開発用（Debug）ビルドを作ります。Apple Developer の登録は不要です。
自分でビルドしたアプリなので、Gatekeeper の警告は出ません。

> Release 構成でのビルドと、`lawmux.app` という名前でのインストール手順は検証中です。

### 使えない機能

- Cloud 関連機能（ログイン、Cloud ターミナル、TunnelExtension）は Manaflow のサーバーと
  Apple の署名を前提にしているため、lawmux では動きません。

## 本家の更新の取り込み

週に一度、GitHub Actions（`lawmux-upstream-check`）が本家の更新を確認し、
未取り込みのコミットがあれば Issue で知らせます。取り込みはローカルで行います。

```sh
./scripts/lawmux-sync-upstream.sh
```

本家から取り込んだ workflow は、同じ Actions が自動で無効にします。
