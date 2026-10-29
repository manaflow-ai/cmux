/// A focused page's input readiness (the pages module's `PageInputReadiness`): the key router's `listFocus`
/// and `pageEditableFocused` facts, read on every key from the readiness its cached facts found.
@MainActor
public protocol KeyFactsReadinessSource: AnyObject {
    var isListFocused: Bool { get }
    var isEditableFocused: Bool { get }
}

/// The objects a window's key facts read on every key, found once by the facts' build. Their
/// flags change with no focus or responder change (a list taking focus in the page, the suggestion list, copy
/// mode, a file turning read only, the page window placed or hidden, the editor's key sequence), so the key
/// router reads them live. Weak: a closed pane's objects go with it, and a missing one reads as off.
/// `Page` is the focused page, whose read-only file and key sequence the app's page services answer.
@MainActor
public struct KeyFactSources<Page: AnyObject> {
    public weak var page: Page?
    public weak var readiness: (any KeyFactsReadinessSource)?
    public weak var suggestions: (any KeyFactsSuggestionSource)?
    public weak var copyMode: (any KeyFactsCopyModeSource)?
    public weak var chromiumPage: (any KeyFactsPageWindowSource)?

    public init(page: Page? = nil, readiness: (any KeyFactsReadinessSource)? = nil, suggestions: (any KeyFactsSuggestionSource)? = nil,
                copyMode: (any KeyFactsCopyModeSource)? = nil, chromiumPage: (any KeyFactsPageWindowSource)? = nil) {
        self.page = page
        self.readiness = readiness
        self.suggestions = suggestions
        self.copyMode = copyMode
        self.chromiumPage = chromiumPage
    }
}
