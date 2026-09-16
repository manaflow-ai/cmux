# CmuxCLISocketAuth

The process-scoped resolver owns credential precedence and memoized source
results. `SocketCredentialResolutionAttempt` separately owns one client's
completion state; it does not cache another password. The CLI recreates the
attempt when configuring credentials and uses it for request/reply, streaming,
and one-way authentication.

An expired operation must not authenticate with a late provider result. A fresh
operation may retry the resolver, including when the previous provider returned
`nil` after its deadline. An in-budget result, including `nil`, completes the
client's attempt. Deadline misses throw `Failure.deadlineExceeded`, distinct from
an in-budget missing password. The CLI translates this to its localized timeout
error, so readiness delivery retries instead of treating it as a permanent
`auth_required` rejection. Synchronous provider calls cannot be forcibly cancelled.

## Deterministic tests

Inject the operation clock instead of delaying a real file or keychain read:

```swift
let instant = Date(timeIntervalSince1970: 1_000)
var attempt = SocketCredentialResolutionAttempt(now: { instant })
let password = try attempt.resolve(
    provider: { _ in "fixture-password" },
    deadline: instant.addingTimeInterval(1)
)
```

The package tests advance an isolated clock during the provider call to exercise
deadline crossings without sleeping. The app-host smoke suite verifies the
public boundary, and separate shipped-CLI socket tests cover protocol framing.

## 日本語

プロセス単位のリゾルバーは認証情報の優先順位と取得結果のキャッシュを管理します。
`SocketCredentialResolutionAttempt` はクライアント単位の完了状態だけを管理し、
パスワードを別途キャッシュしません。CLI は認証情報の設定時にこの値を作り直し、
通常の要求、ストリーミング、一方向の送信で共通して使用します。

期限を過ぎた処理は、遅れて取得した認証情報で認証を行いません。次の処理は、
前回の取得結果が期限後の `nil` だった場合も含め、リゾルバーを再度呼び出せます。
期限内の取得は、結果が `nil` でも完了として扱います。期限切れの場合は、パスワードが
見つからない場合と区別して `Failure.deadlineExceeded` を送出します。CLI はこれを
ローカライズされたタイムアウトエラーに変換するため、準備完了の通知は永続的な
`auth_required` エラーとして終了せずに再試行できます。同期的な取得処理を強制的に
キャンセルするものではありません。テストでは上記のように時計を注入し、実際の
ファイルやキーチェーンの読み取りを遅延させずに、期限をまたぐ動作を検証します。
