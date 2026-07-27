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
- `RemoteTmuxCommandBuilder` — shared remote `tmux` resolution and argv preservation.
- `WorkspaceRemoteTerminalProfile` — durable shell-or-named-tmux terminal intent.
- `WorkspaceRemoteTerminalTransport` — the persisted SSH-or-Mosh interactive terminal preference.

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
    remoteMoshProbeFailedMessage: "Mosh capability check failed; using SSH."
).command()
```

Transport and terminal program are orthogonal values, so a Mosh workspace can durably
restore a named tmux session without moving daemon or proxy traffic away from SSH:

```swift
let profile = WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "agent-main")
let remoteArguments = profile?.remoteCommandArguments
```

## Testing

Everything here is a value transform, so tests need no app, no AppKit, and no user-owned state:

```swift
import Testing
import CmuxFoundation

@Test func plainStringIsQuoted() {
    #expect("hello".javaScriptStringLiteral == "\"hello\"")
}
```
