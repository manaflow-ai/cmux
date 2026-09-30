import Foundation

/// Pure scheduling policy for coalescing computer-use state-directory events.
struct ComputerUseMenuBarRefreshPolicy: Sendable {
    static let live = ComputerUseMenuBarRefreshPolicy(minimumEventReloadInterval: 0.15)

    let minimumEventReloadInterval: TimeInterval

    func reloadDeadline(
        forEventAt eventDate: Date,
        featureEnabled: Bool,
        showInMenuBar: Bool
    ) -> Date? {
        guard featureEnabled && showInMenuBar else { return nil }
        return eventDate.addingTimeInterval(minimumEventReloadInterval)
    }

    func stateExpirationDeadline(
        lastActionAt: Date,
        recentActivityInterval: TimeInterval
    ) -> Date {
        // The repository treats a state exactly at the freshness boundary as
        // recent. Reuse the debounce interval as a small leeway so the expiry
        // refresh runs strictly after that inclusive boundary and cannot
        // repeatedly reschedule itself with a zero-length delay.
        lastActionAt.addingTimeInterval(
            max(0, recentActivityInterval) + minimumEventReloadInterval
        )
    }
}
