# CmuxAcpmux

The acpmux backend for the cmux agent GUI: an implementation of
`CmuxConversation`'s `ConversationBackend` that speaks acpmux's protocol
(ACP plus `_acpmux/*`, newline-delimited JSON-RPC) over any
`ConversationByteStream`.

- `AcpmuxBackend`: connects, reconnects with backoff (at most 30 s apart),
  keeps the session list (`_acpmux/watch`), creates sessions idempotently,
  runs commands, uploads files. `singleAttachment` (iOS) keeps one session open.
- `AcpmuxFeed`: one session's events. Attaches with the newest page,
  replays after its cursor on a gap or an `_acpmux/lagged` notice, pages
  backwards with `beforeSeq`, and resumes after a reconnect.
- `AcpmuxEventDecoder`: the only code that knows acpmux's record shapes.
- `UnixSocketStreamOpener`: the macOS transport. iOS supplies its own opener
  over the paired Mac's relay lanes.

```swift
let backend = AcpmuxBackend(opener: UnixSocketStreamOpener { await supervisor.socketPath() }, clientName: "cmux-mac", singleAttachment: false)
let model = ConversationModel(backend: backend, conversationID: nil, settings: settings, outbox: outbox, outboxKey: tabID)
```

Tests: `swift test` runs the decoder tests. The end-to-end tests drive a real
daemon when `ACPMUX_BIN` (an acpmux binary) and `ACPMUX_FAKE_AGENT` (its
`tests/fake_agent.py`) are set; otherwise they return early.
