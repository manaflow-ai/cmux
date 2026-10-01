# CmuxConversation

The backend-agnostic core of the cmux agent GUI (macOS and iOS): the
conversation model, the events a backend adapter produces, the commands a
GUI sends, a reducer that folds events into state, and the protocols a
backend implements. acpmux is the first backend (`CmuxAcpmux`); nothing here
depends on it.

Layers, top to bottom:

- `ConversationModel` (`@MainActor @Observable`): what a chat view binds to.
  Sends show instantly, live in an `OutboxStoring` until confirmed, and are
  resent (never run twice) after a dropped link or restart.
- `ConversationReducer`: a pure fold of `ConversationEnvelope`s into
  `ConversationState`. Duplicates are dropped; an older page refolds the
  loaded history so pages that start mid-turn come out right.
- `ConversationBackend` / `ConversationFeed`: a backend lists, opens and
  commands conversations; a feed delivers history then live events and
  recovers from gaps on its own (the cursor is opaque).
- `ConversationStreamOpening` / `ConversationByteStream`: the transport,
  chosen per machine (a Unix socket on this Mac, a relay lane from iOS).

Testing: the reducer is a value type, so tests fold literal envelopes:

```swift
var state = ConversationState()
ConversationReducer().apply([envelope], to: &state)
#expect(state.items.map(\.id) == ["user:a"])
```

`swift test` runs the suite without the app.
