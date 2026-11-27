import AppKit
import Foundation
import WebKit

/// Keeps authenticated placement and isolated recovery ordering identical
/// across Workspace and Dock browser hosts.
@MainActor
final class BrowserAppLinkPlacementPolicy {
    typealias RequestPlacement = (URLRequest, WKWebsiteDataStore) -> Bool
    typealias URLPlacement = (URL, WKWebsiteDataStore) -> Bool

    private let openInSystemBrowser: (URL) -> Bool

    init(
        openInSystemBrowser: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.openInSystemBrowser = openInSystemBrowser
    }

    func openNavigation(
        _ navigation: BrowserAppSessionNavigation,
        openInPreferredPane: RequestPlacement,
        openHorizontalSplit: RequestPlacement,
        openInSourcePane: RequestPlacement,
        isBrowserAvailable: () -> Bool
    ) -> Bool {
        // The handoff coordinator owns the one-shot recovery path. Returning
        // false here makes it recover the destination once; opening it here
        // would duplicate that fallback when availability changes mid-placement.
        guard isBrowserAvailable() else { return false }
        if openInPreferredPane(
            navigation.request,
            navigation.websiteDataStore
        ) {
            return true
        }
        guard isBrowserAvailable() else { return false }
        if openHorizontalSplit(
            navigation.request,
            navigation.websiteDataStore
        ) {
            return true
        }
        guard isBrowserAvailable() else { return false }
        return openInSourcePane(
            navigation.request,
            navigation.websiteDataStore
        )
    }

    func recover(
        _ destinationURL: URL,
        openInPreferredPane: URLPlacement,
        openHorizontalSplit: URLPlacement,
        openInSourcePane: URLPlacement,
        isBrowserAvailable: () -> Bool
    ) -> Bool {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        guard isBrowserAvailable() else {
            return openInSystemBrowser(destinationURL)
        }
        if openInPreferredPane(
            destinationURL,
            websiteDataStore
        ) {
            return true
        }
        guard isBrowserAvailable() else {
            return openInSystemBrowser(destinationURL)
        }
        if openHorizontalSplit(
            destinationURL,
            websiteDataStore
        ) {
            return true
        }
        guard isBrowserAvailable() else {
            return openInSystemBrowser(destinationURL)
        }
        return openInSourcePane(
            destinationURL,
            websiteDataStore
        ) || openInSystemBrowser(destinationURL)
    }
}
