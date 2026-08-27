# cmux-tui

tmux 風のターミナル TUI です。詳細な英語ドキュメントは
[README.md](README.md) を参照してください。

## npm パッケージのインストールと更新

`cmux` npm パッケージは依存関係を持たない小さなランチャーです。初回起動時に
現在のプラットフォーム用の `cmux-tui-<platform>` パッケージを npm レジストリから
ダウンロードし、sha512 整合性を確認してランチャー専用キャッシュに保存します。

書き込み可能なランチャーキャッシュは起動前にレジストリの tarball と再検証します。
管理者が用意した完全な読み取り専用キャッシュはオフラインで起動できます。

```bash
npx cmux update
npx cmux update --check
```

`cmux update` はプラットフォーム用バイナリの通常更新に使います。npm ランチャー自体を
更新する場合は `npx cmux@latest` を使います。`npx` は cmux の起動前に npm の `_npx`
キャッシュへアクセスすることがあり、古いキャッシュでは `ENOTEMPTY` が発生する場合が
あります。詳しい復旧手順は
[パッケージのインストールと更新](docs/getting-started.ja.md) を参照してください。
