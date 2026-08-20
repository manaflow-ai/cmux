# CmuxFoundation

Shared low-level primitives for cmux with no internal package dependencies. This is the
bottom of the package dependency graph: encoding/text helpers, value types, and other
cross-cutting utilities that several domains need, with nothing in here depending on AppKit,
SwiftUI, or another cmux package.

It exists as the leaf every other package and the app target can depend on without creating
a cycle. Keep it dependency-free.

Foundation helpers are exposed as extensions on existing types rather than free functions,
so call sites read naturally (`value.javaScriptStringLiteral`, not `f(value)`).

## Contents

- `String.javaScriptStringLiteral` — the string encoded as a quoted JavaScript string literal.
- `SSHAgentSocketResolver` — OpenSSH option parsing and SSH agent socket path normalization.
- `MoshTerminalCommandBuilder` — a pure Mosh startup-command builder with explicit SSH fallback.
- `MoshRemoteIPMode` — the address-discovery mode selected for a Mosh connection.
- `RemoteTmuxCommandBuilder` — shared remote `tmux` resolution and argv preservation.
- `WorkspaceRemoteTerminalProfile` — durable shell-or-named-tmux terminal intent.
- `WorkspaceRemoteTerminalTransport` — the persisted SSH-or-Mosh interactive terminal preference.
- `CLISocketSentryPolicy`: trusted Codex sandbox provenance for CLI socket `EPERM` filtering.
- `CmuxCodexConfigEditor` — pure install and uninstall transforms for cmux's Codex `config.toml` hooks.
- `MainActorDeferredActionScheduler` — replaceable clock-driven main-actor work
  whose queued actions cannot retain prior scheduled actions.
- `MainActorCoalescingDeadlineTimer` — one persistent timer handle for hot,
  synchronous streams of deadline updates.
- `MainActorRepeatingActionScheduler` — one persistent timer handle for a
  lifecycle-bound repeating main-actor action.
- `MainActorTaskStore` — keyed replaceable task ownership that keeps task
  handles out of captured SwiftUI value snapshots.

## Usage

```swift
import CmuxFoundation

let literal = userText?.javaScriptStringLiteral ?? "null"
webView.evaluateJavaScript("setValue(\(literal))")
```

Callers supply complete SSH argv prefixes and localized diagnostics to the Mosh builder, which
keeps process execution and localization outside this dependency-free package:

```swift
let command = MoshTerminalCommandBuilder(
    capabilityProbeSSHArguments: ["ssh", "-o", "RemoteCommand=none"],
    sessionSSHArguments: ["ssh", "-o", "RemoteCommand=none", "-p", "2222"],
    destination: "dev@example.com",
    remoteCommandArguments: [],
    sshFallbackCommand: "ssh -p 2222 dev@example.com",
    localMoshMissingMessage: "Mosh is unavailable locally; using SSH.",
    localMoshUnsupportedMessage: "Mosh is too old for shared SSH setup; using SSH.",
    remoteMoshMissingMessage: "mosh-server is unavailable remotely; using SSH.",
    remoteMoshProbeFailedMessage: "Mosh capability check failed; using SSH.",
    remoteBootstrapInstallFailedMessage: "Remote bootstrap install failed; using SSH.",
    remoteMoshAddressFallbackMessage: "Remote SSH address is unusable; using local Mosh resolution."
).command()
```

Transport and terminal program are orthogonal values, so a Mosh workspace can durably
restore a named tmux session without moving daemon or proxy traffic away from SSH:

```swift
let profile = WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "agent-main")
let remoteArguments = profile?.remoteCommandArguments
```

Codex hook edits are pure transforms; callers own the file read/write boundary:

```swift
let editor = CmuxCodexConfigEditor()
let result = editor.installingHooks(in: configContents, trustEntries: trustEntries)
try result.content.write(to: configURL, atomically: true, encoding: .utf8)
```

CLI telemetry may suppress socket-connect `EPERM` only when the process
environment contains a known restricted `CODEX_SANDBOX` value:

```swift
let policy = CLISocketSentryPolicy(environment: ProcessInfo.processInfo.environment)
let isExpected = SentryNoiseFilter().isExpectedCLISocketTransportFailure(
    stage: stage,
    message: errorMessage,
    allowSandboxPolicyDenial: policy.allowsSandboxPolicyDenial
)
```

Pass the process environment directly. Missing, unknown, and unrestricted
`CODEX_SANDBOX` values keep the error visible.

## Testing

Tests need no app, AppKit lifecycle, or user-owned state:

```swift
import Testing
import CmuxFoundation

@Test func plainStringIsQuoted() {
    #expect("hello".javaScriptStringLiteral == "\"hello\"")
}
```

The Codex editor takes fixture strings, so its install/reinstall/uninstall behavior is
covered without an app host or a user-owned `~/.codex` directory:

```swift
let editor = CmuxCodexConfigEditor()
let installed = editor.installingHooks(in: fixture, trustEntries: entries)
let restored = editor.uninstallingHooks(
    from: installed.content,
    removingHookTrustEntries: entries
)
```

Deferred-action tests inject a controllable `Clock<Duration>` and advance it
instead of waiting for wall time:

```swift
let scheduler = MainActorDeferredActionScheduler(clock: testClock)
scheduler.schedule(after: .milliseconds(50)) {
    receivedAction = true
}
```

Hot repeating work keeps one timer handle and must be cancelled at its owner’s
lifecycle boundary:

```swift
let ticker = MainActorRepeatingActionScheduler()
ticker.startIfIdle(every: .milliseconds(16)) {
    refreshPointerState()
}
ticker.cancel()
```

Replaceable async work uses a reference-owned task store. The store retains
only weak task-owner references, so an operation that captures its owner cannot
form an owner-to-task retain cycle:

```swift
let tasks = MainActorTaskStore<String>()
tasks.replace("search", priority: .userInitiated) {
    await rebuildSearchIndex()
}
```
