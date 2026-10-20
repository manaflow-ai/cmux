import Foundation

/// Runs app-link authentication and recovery independently of the browser's
/// current host so Workspace and Dock panels share one lifecycle contract.
@MainActor
final class BrowserAppLinkHandoffCoordinator {
    private let registry = BrowserAppLinkHandoffRegistry()

    @discardableResult
    func start(
        sourcePanelID: UUID,
        destinationURL: URL,
        isCurrent: @escaping @MainActor () -> Bool,
        openNavigation: @escaping @MainActor (BrowserAppSessionNavigation) -> Bool,
        openRecovery: @escaping @MainActor () -> Bool
    ) -> Bool {
        _ = registry.start(
            sourcePanelID: sourcePanelID,
            destinationURL: destinationURL
        ) { [weak self] in
            guard let self else { return }
            await self.performHandoff(
                destinationURL: destinationURL,
                isCurrent: isCurrent,
                openNavigation: openNavigation,
                openRecovery: openRecovery
            )
        }
        // A duplicate request is already owned by the registry, so the browser
        // should still treat the app link as handled.
        return true
    }

    func cancel(sourcePanelID: UUID) {
        registry.cancel(sourcePanelID: sourcePanelID)
    }

    func cancelAll() {
        registry.cancelAll()
    }

    private func performHandoff(
        destinationURL: URL,
        isCurrent: @escaping @MainActor () -> Bool,
        openNavigation: @escaping @MainActor (BrowserAppSessionNavigation) -> Bool,
        openRecovery: @escaping @MainActor () -> Bool
    ) async {
        guard let auth = AppDelegate.shared?.auth else {
            recoverIfCurrent(isCurrent: isCurrent, openRecovery: openRecovery)
            return
        }

        var replayedAfterSignIn = false
        while !Task.isCancelled {
            guard isCurrent() else { return }
            var outcome = await auth.browserAppSession.request(
                destinationURL: destinationURL
            )
            guard !Task.isCancelled, isCurrent() else { return }
            if outcome.shouldRetry {
                outcome = await auth.browserAppSession.request(
                    destinationURL: destinationURL
                )
                guard !Task.isCancelled, isCurrent() else { return }
            }
            if outcome.recoveryAction == .beginSignIn,
               !replayedAfterSignIn {
                replayedAfterSignIn = true
                let signedIn = await auth.browserSignIn.beginSignIn().value
                guard !Task.isCancelled, isCurrent() else { return }
                if signedIn { continue }
            }
            if outcome.recoveryAction != nil {
                recoverIfCurrent(
                    isCurrent: isCurrent,
                    openRecovery: openRecovery
                )
                return
            }
            guard case let .navigation(navigation) = outcome else {
                recoverIfCurrent(
                    isCurrent: isCurrent,
                    openRecovery: openRecovery
                )
                return
            }
            guard auth.browserAppSession.isCurrent(
                generation: navigation.generation,
                authSessionGeneration: navigation.authSessionGeneration
            ), openNavigation(navigation) else {
                recoverIfCurrent(
                    isCurrent: isCurrent,
                    openRecovery: openRecovery
                )
                return
            }
            return
        }
    }

    private func recoverIfCurrent(
        isCurrent: @MainActor () -> Bool,
        openRecovery: @MainActor () -> Bool
    ) {
        guard !Task.isCancelled, isCurrent() else { return }
        _ = openRecovery()
    }
}
