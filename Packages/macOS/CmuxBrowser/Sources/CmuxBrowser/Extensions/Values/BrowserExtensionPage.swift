public import Foundation

/// The Chromium pages for finding and managing extensions.
public enum BrowserExtensionPage: String, Sendable, CaseIterable {
    /// The Chrome Web Store extensions category.
    case webStore = "webstore"
    /// `chrome://extensions`.
    case management = "manage"

    /// The page's address.
    public var url: URL {
        switch self {
        case .webStore:
            // Literal URL; the fallback never runs.
            return URL(string: "https://chromewebstore.google.com/category/extensions") ?? URL(fileURLWithPath: "/")
        case .management:
            return URL(string: "chrome://extensions/") ?? URL(fileURLWithPath: "/")
        }
    }
}
