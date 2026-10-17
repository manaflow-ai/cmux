# CmuxConversationHost

`CmuxConversationHost` is the macOS composition package for managed Codex, Claude Code, and OpenCode sessions. It owns the provider-native process/server adapters and the account-scoped durable `ConversationBroker`; iOS and app targets consume the lower-level `CmuxConversation` wire package through an injected client.

The broker stores a crash-safe ordered journal per session. Commands carry a durable command ID plus generation and turn preconditions. A command that cannot be reconciled is returned as `uncertain`; callers inspect its receipt after reconnect rather than replaying it blindly. Live event streams are bounded and fail explicitly on overflow so callers can snapshot and replay from the last cursor.

```swift
let broker = try ConversationBroker(directory: accountDirectory)
let session = try await broker.createSession(ConversationCreateRequest(
    requestID: commandID,
    provider: .codex,
    workspaceID: workspaceID,
    directory: trustedDirectory,
    launchTarget: .local(directory: trustedDirectory)
))
let stream = await broker.events(sessionID: session.id, after: 0)
```

Provider launch targets are trusted host values. Cloud and unsupported native transports return explicit provider errors. `ProcessConversationTransportFactory` resolves local executables from injected overrides and trusted paths; SSH targets resolve the provider command on the remote login shell.
