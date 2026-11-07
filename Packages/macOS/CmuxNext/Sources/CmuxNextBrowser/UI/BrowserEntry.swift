public import AppKit

/// A live browser page and its toolbar state. A pane's browser tabs share one chrome (`BrowserPaneChrome`, #32909
/// step B): the host writes the tab's hooks and per-tab presentation to `state`, never to a chrome, and reads the
/// chrome that shows the tab now from `chrome` (nil while its pane shows another tab).
public final class BrowserEntry {
    public let tab: any BrowserTab
    public let state = BrowserChromeTabState()
    @MainActor public var chrome: BrowserChromeView? { state.chrome }
    /// Owns the chrome's (weak) Extensions menu handler.
    public var extensionMenuHandler: (any ExtensionMenuHandling)?

    // No isolated-deinit hop inside an action's task-local scope (cx-t7hu).
    nonisolated deinit {
        BrowserTabRetirement(tab: tab, state: state).retire()
    }

    @MainActor
    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(),
                history: (any BrowserHistoryStore)? = nil) {
        self.tab = tab
        state.suggestionEngine = suggestionEngine
        // Its loads are recorded from the start, shown or not. It follows before history is set: a page already
        // finished when installed (a restored one, marked by the cache right after) is not a new visit (as before).
        state.loads.follow(tab)
        state.history = history
    }

    public func close() {
        BrowserTabRetirement(tab: tab, state: state).retire()
    }
}
