# lawmux（この fork）での作業ルール

このリポジトリは manaflow-ai/cmux の個人 fork「lawmux」です。`CLAUDE.md` と
`skills/` は本家チーム向けのまま残してあり、次の点は lawmux 側のルールが優先します。
詳細は [LAWMUX.md](../../LAWMUX.md)。

## 改造の方針

- 本家の更新を取り込み続けるので、変更は最小限にする。許されるのは
  (1) 定数の差し替え（`// lawmux:` コメントを付ける）、(2) `lawmux-*` という名前の新規ファイル。
- 使わない機能やディレクトリを削除しない。本家のテスト、workflow、`scripts/reload*.sh`、
  README の多言語版は触らない。本家のテストが lawmux で一部失敗するのは想定内。
- `web/`、`workers/`、`services/` などの BUSL ディレクトリは触らない（lawmux では使わない）。

## ビルドと確認

- Release ビルドと `/Applications/lawmux.app` への入れ替えは
  `./scripts/lawmux-build-release.sh --install --open`。この fork では素の `xcodebuild`
  （このスクリプト経由）を使ってよい。本家の `reload.sh --launch` はチーム認証が要るので使えない。
- `/Applications/cmux.app`（`com.cmuxterm.app`）は本家のアプリで、ユーザーが使っている。
  絶対に終了・置き換えしない。lawmux（`com.lawrenceturnerw.lawmux`）の終了は作業上必要なら行ってよい。
- 変更後は `python3 scripts/verify-local.py` を通し、Swift を触ったらビルドまで確認する。

## ブランチ運用

- 機能追加・修正は `feature/<name>` ブランチで作業し、push して PR を作る。ユーザーが動作確認
  したあとにマージする（`gh pr merge --merge --delete-branch`）。
- `main` に直接 push してよいのは、本家の取り込み（`scripts/lawmux-sync-upstream.sh`）と
  ドキュメントの軽微な修正だけ。
- PR 本文の末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を付ける。

## 本家の取り込み

- `./scripts/lawmux-sync-upstream.sh`（Issue「upstream updates pending」が合図）。
- 本家のタグは写さない。lawmux のタグは `lawmux-vX.Y.Z`。
