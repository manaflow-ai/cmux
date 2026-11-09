public import Observation

/// The closed-tab list's change signal (`ClosedTabsFeed.changes`). An
/// Observation of `revision` fires after the feed saw a change, never
/// before, so a reader sees the closed tab and the tab's absence together.
@Observable @MainActor
public final class ClosedTabChanges {
    public private(set) var revision: UInt64 = 0

    public init() {}

    public func bump() { revision &+= 1 }
}
