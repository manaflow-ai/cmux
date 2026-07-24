import CmuxMobileSupport
import Foundation

/// Search engines available for the mobile browser address bar.
public enum MobileBrowserSearchEngine: String, CaseIterable, Codable, Sendable {
    /// DuckDuckGo search.
    case duckDuckGo = "duckduckgo"
    /// Google search.
    case google
    /// Bing search.
    case bing

    /// Localized display name.
    public var displayName: String {
        switch self {
        case .duckDuckGo:
            return L10n.string("mobile.browser.searchEngine.duckDuckGo", defaultValue: "DuckDuckGo")
        case .google:
            return L10n.string("mobile.browser.searchEngine.google", defaultValue: "Google")
        case .bing:
            return L10n.string("mobile.browser.searchEngine.bing", defaultValue: "Bing")
        }
    }

    /// Query URL template consumed by ``BrowserURLResolver``.
    public var searchTemplate: String {
        switch self {
        case .duckDuckGo:
            return BrowserURLResolver.defaultSearchTemplate
        case .google:
            return "https://www.google.com/search?q=%@"
        case .bing:
            return "https://www.bing.com/search?q=%@"
        }
    }
}
