/// Couples a recoverable route to the lifetime of its weak `TabManager` owner.
///
/// `MainWindowRouteLedger` deliberately does not retain the manager while
/// SwiftUI replaces a window context. The manager owns this registration, so
/// an abandoned replacement tears down the exact route and its transferred
/// Dock even when no later route lookup or terminal-registry sweep occurs.
@MainActor
final class RecoverableMainWindowRouteOwnerRegistration {
    // SAFETY: these weak references are installed on the main actor and copied
    // only by `deinit` before the cleanup is handed back to the main actor.
    nonisolated(unsafe) private weak var appDelegate: AppDelegate?
    nonisolated(unsafe) private weak var route: RecoverableMainWindowRoute?

    init(appDelegate: AppDelegate, route: RecoverableMainWindowRoute) {
        self.appDelegate = appDelegate
        self.route = route
    }

    func observes(_ route: RecoverableMainWindowRoute) -> Bool {
        self.route === route
    }

    deinit {
        let appDelegate = appDelegate
        let route = route
        Task { @MainActor in
            guard let route else { return }
            appDelegate?.retireRecoverableMainWindowRouteIfCurrent(
                route,
                reason: "tabManager.deinit"
            )
        }
    }
}
