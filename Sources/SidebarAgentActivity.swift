import Foundation

/// Immutable state for one agent shown by a workspace row.
struct SidebarAgentActivity: Equatable, Sendable, Identifiable {
    let id: String
    let statusKey: String
    let state: SidebarAgentResolvedState
    let startedAt: TimeInterval?

    var elapsedStart: TimeInterval? {
        guard state == .running,
              let startedAt,
              startedAt.isFinite,
              startedAt > 0 else {
            return nil
        }
        return startedAt
    }

    func elapsed(at now: Date) -> TimeInterval? {
        guard let elapsedStart else { return nil }
        let value = now.timeIntervalSince1970 - elapsedStart
        guard value.isFinite else { return nil }
        return max(0, value)
    }
}
