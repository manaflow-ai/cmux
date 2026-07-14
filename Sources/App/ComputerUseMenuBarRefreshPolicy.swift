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
        guard featureEnabled || showInMenuBar else { return nil }
        return eventDate.addingTimeInterval(minimumEventReloadInterval)
    }
}
