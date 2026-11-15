public import Foundation

/// One omnibar match for preloading, as Chrome's `AutocompleteMatch` type and
/// destination (the fork's `cmux_omnibox_match_type_t`).
public nonisolated struct OmniboxPreloadMatch: Equatable, Hashable, Sendable {
    public enum Kind: Int32, Sendable {
        case urlWhatYouTyped = 0
        case historyURL = 1
        case bookmarkTitle = 2
        case openTab = 3
        case searchWhatYouTyped = 4
        case searchSuggest = 5
        case searchHistory = 6
    }

    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// What the tab did for the omnibar's default match (Chrome's
/// `AutocompleteActionPredictor::Action`), or `.unavailable` (no Chromium
/// fork API 33, or not a Chromium tab).
public nonisolated enum OmniboxPreloadAction: Int32, Sendable {
    case prerender = 0
    case preconnect = 1
    case none = 2
    case unavailable = -1
}

/// A tab that preloads what the omnibar is about to load: the Chromium tab,
/// with Chrome's own predictor, preconnect and prerender
/// (`CEFTab+OmniboxPreload`). The omnibar feeds it through `OmnibarController`.
@MainActor public protocol BrowserOmniboxPreloading: AnyObject {
    /// The typed text or its matches changed (Chrome's
    /// `ChromeOmniboxClient::OnTextChanged`): `matches` first holds the default
    /// match, what Enter loads.
    @discardableResult
    func omniboxPreload(text: String, matches: [OmniboxPreloadMatch]) -> OmniboxPreloadAction
    /// The edit ended: `opened` loaded (nil for a revert); `learn` is false
    /// when Chrome would not learn from it (popup closed, Paste and Go, blur).
    func omniboxPreloadEnded(opened: URL?, learn: Bool)
}
