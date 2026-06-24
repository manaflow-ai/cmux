public import WebKit

/// Mirrors the opener's WebKit browsing context for popup windows.
///
/// A popup window opened by ``WKUIDelegate`` must share the opener panel's
/// ``WKWebsiteDataStore`` so cookies, storage, and the (default vs ephemeral vs
/// remote-workspace-scoped) data partition match the page that opened it.
public struct BrowserPopupBrowserContext {
    /// The website data store the popup's web view must reuse.
    public let websiteDataStore: WKWebsiteDataStore

    /// Creates a popup browsing context bound to the opener's data store.
    public init(websiteDataStore: WKWebsiteDataStore) {
        self.websiteDataStore = websiteDataStore
    }
}
