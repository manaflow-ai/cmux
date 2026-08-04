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

    func recover(
        _ destinationURL: URL,
        openInPreferredPane: URLPlacement,
        openHorizontalSplit: URLPlacement,
        openInSourcePane: URLPlacement
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
