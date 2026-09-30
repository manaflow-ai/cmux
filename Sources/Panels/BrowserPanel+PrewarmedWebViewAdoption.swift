import Foundation
import CmuxBrowser
import WebKit

/// Hover-prewarm adoption support for ``BrowserPanel``: profile resolution
/// shared with prewarm callers, and the eligibility gate the initializer uses
/// to swap a pool-prewarmed webview in place of a cold load.
extension BrowserPanel {
    /// The profile a panel would use for the given requested ID. Shared with
    /// prewarm callers so a prewarmed webview and the panel that later adopts
    /// it resolve to the same profile and website data store.
    static func resolvedProfileID(requested: UUID?) -> UUID {
        let requestedProfileID = requested ?? BrowserProfileStore.shared.effectiveLastUsedProfileID
        return BrowserProfileStore.shared.profileDefinition(id: requestedProfileID) != nil
            ? requestedProfileID
            : BrowserProfileStore.shared.builtInDefaultProfileID
    }

    /// A prewarmed webview matching this panel's initial navigation exactly,
    /// or nil for a normal cold load. Remote workspaces, request-based
    /// navigations, and render-deferred panels never adopt.
    static func claimedPrewarmedWebView(
        isRemoteWorkspace: Bool,
        initialRequest: URLRequest?,
        renderInitialNavigation: Bool,
        initialURL: URL?,
        profileID: UUID,
        websiteDataStore: WKWebsiteDataStore
    ) -> CmuxWebView? {
        guard !isRemoteWorkspace,
              initialRequest == nil,
              renderInitialNavigation,
              let initialURL else {
            return nil
        }
        return BrowserPrewarmedWebViewPool.shared.claim(
            url: initialURL,
            profileID: profileID,
            websiteDataStore: websiteDataStore
        )
    }
}
