import AppKit
import Foundation
import WebKit

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

/// Keeps authenticated placement and isolated recovery ordering identical
/// across Workspace and Dock browser hosts.
@MainActor
enum BrowserAppLinkPlacementPolicy {
    typealias RequestPlacement = (URLRequest, WKWebsiteDataStore) -> Bool
    typealias URLPlacement = (URL, WKWebsiteDataStore) -> Bool

    static func openNavigation(
        _ navigation: BrowserAppSessionNavigation,
        openInPreferredPane: RequestPlacement,
        openHorizontalSplit: RequestPlacement,
        openInSourcePane: RequestPlacement
    ) -> Bool {
        openInPreferredPane(
            navigation.request,
            navigation.websiteDataStore
        ) || openHorizontalSplit(
            navigation.request,
            navigation.websiteDataStore
        ) || openInSourcePane(
            navigation.request,
            navigation.websiteDataStore
        )
    }

    static func recover(
        _ destinationURL: URL,
        openInPreferredPane: URLPlacement,
        openHorizontalSplit: URLPlacement,
        openInSourcePane: URLPlacement,
        openInSystemBrowser: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        return openInPreferredPane(
            destinationURL,
            websiteDataStore
        ) || openHorizontalSplit(
            destinationURL,
            websiteDataStore
        ) || openInSourcePane(
            destinationURL,
            websiteDataStore
        ) || openInSystemBrowser(destinationURL)
    }
}
