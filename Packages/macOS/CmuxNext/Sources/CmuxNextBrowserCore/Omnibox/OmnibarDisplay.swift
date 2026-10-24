public import Observation

/// How the omnibars of one suggestion engine show addresses, from cmux.json
/// (`browser.omnibar.showFullURLs`, `OmniboxSuggestionEngine.apply`). Each
/// address bar follows it live (Chrome's "Always show full URLs").
@Observable
public final class OmnibarDisplay {
    /// The bar shows the whole address at rest: scheme, `www.` and the
    /// trailing slash kept (Chrome `omnibox.prevent_url_elisions`).
    public package(set) var showsFullURLs = false

    /// The right-click menu's toggle: the App writes the setting, which
    /// comes back through `OmniboxSuggestionEngine.apply`. Nil hides the
    /// menu item (no setting to write).
    public var setShowsFullURLs: ((Bool) -> Void)?

    /// "Manage Search Engines…" in the right-click menu: the App opens
    /// Settings at the search engine. Nil hides the item.
    public var manageSearchEngines: (() -> Void)?

    public init() {}
}
