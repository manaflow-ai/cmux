import Observation

/// The closed-tab list's change signal (`ClosedTabTracker.changes`). An
/// Observation of `revision` fires after the tracker applied a change, never
/// before, so a reader sees the closed tab and the tab's absence together.
@Observable @MainActor
final class ClosedTabChanges {
    private(set) var revision: UInt64 = 0

    func bump() { revision &+= 1 }
}
