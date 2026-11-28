#if os(iOS)
import Foundation

// Value snapshots for the Computers screen rows. Nothing here holds an
// `@Observable` store, so rows that consume these sit safely below the screen's
// `List` boundary (see AGENTS.md snapshot-boundary rule).

/// Live presence for a computer, rolled up from the presence service's
/// per-instance heartbeats (a computer is online if any instance is online).
/// `nil` when the presence service has no record, in which case the row falls
/// back to the registry "last seen" hint.
enum DeviceTreePresence: Equatable {
    case online
    case offline(lastSeenAt: Date)
}
#endif
