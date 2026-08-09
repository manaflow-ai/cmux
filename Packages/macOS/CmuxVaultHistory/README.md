# CmuxVaultHistory

`CmuxVaultHistory` owns the locale-independent values, bounded JSONL
persistence, and deterministic grouping used by the macOS History timeline.
The app target owns lifecycle coordination and localized presentation.

Construct a repository with an explicit file URL. Passing `nil` gives tests an
in-memory repository with the same retention behavior:

```swift
let store = VaultHistoryEventStore(fileURL: nil)
let accepted = await store.append(event)
let events = await store.recentEvents()
```

Grouping is a pure operation. Inject `now` at the call site and inspect group
identities without loading AppKit or SwiftUI:

```swift
let groups = VaultHistoryGrouper(calendar: calendar).groups(
    events: events,
    by: .date,
    now: now
)
```
