# CmuxConversationTransfer

`CmuxConversationTransfer` converts provider-normalized conversation turns into
a compact, role-labeled handoff prompt. It intentionally owns no transcript I/O;
the app supplies `ConversationTurn` values from provider adapters.

```swift
let message = try ConversationTransferService().message(
    for: [
        ConversationTurn(id: 0, role: .user, text: "Inspect the parser"),
        ConversationTurn(id: 1, role: .assistant, text: "The final field is dropped"),
    ],
    sourceDisplayName: "Codex"
)
```

The package test target constructs the service directly with value fixtures, so
tests do not launch AppKit or read the user's filesystem.
