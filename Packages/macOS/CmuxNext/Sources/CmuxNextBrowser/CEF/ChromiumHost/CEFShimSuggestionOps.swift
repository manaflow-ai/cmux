import Foundation

/// The shim's suggestion calls (task 061): Chromium's autofill, password and `<datalist>` rows as
/// SUGGESTIONS events, and the app's answers. Both do nothing with a fork below API 31; in host mode
/// the first is a preinit op the remote shim replays to every new host, the second one control op.
nonisolated struct CEFShimSuggestionOps {
    /// The fork API whose suggestion handler sends the rows as data (task 172).
    static let forkAPI: Int32 = 31

    /// `cmux_shim_set_suggestion_events`: 1 sends every browser's suggestions to the app.
    let setEvents: @convention(c) (Int32) -> Void
    /// `cmux_shim_browser_suggestion_action`: browser, token, ``ChromiumHostSuggestionAction``, row.
    let action: @convention(c) (Int32, Int64, Int32, Int32) -> Int32

    init(_ r: CEFShimLibrary.Resolver) throws(CEFShimLibrary.LoadError) {
        setEvents = try r("cmux_shim_set_suggestion_events")
        action = try r("cmux_shim_browser_suggestion_action")
    }

    /// One answer for the rows of `token`, one-way: Chromium's reply is its next SHOW or HIDE.
    func send(_ action: ChromiumHostSuggestionAction, token: Int64, row: Int, browser: Int32) {
        _ = self.action(browser, token, action.rawValue, Int32(clamping: row))
    }
}

extension CEFRuntime {
    /// The host sends its suggestions to cmux's list: host mode with feature `chromiumHostSuggestions`
    /// and a fork whose suggestion handler sends them (``CEFShimSuggestionOps/forkAPI``). Below that
    /// fork Chromium still draws them itself (a `<datalist>` as a hosted page popup).
    var drawsSuggestionsInCmux: Bool {
        hostStart?.drawsSuggestions == true && forkAPIVersion >= CEFShimSuggestionOps.forkAPI
    }
}

/// A pane's page view answers the suggestions of the browser its pane shows
/// (``ChromiumHostSuggestionWire``), through the runtime's shim: the remote shim in host mode.
final class CEFPaneSuggestionWire: ChromiumHostSuggestionWire {
    private weak var pane: CEFPaneHost?

    init(pane: CEFPaneHost) {
        self.pane = pane
    }

    /// The shown tab's browser, while the host draws its suggestions in cmux.
    var suggestionBrowser: Int32? {
        guard let pane, pane.runtime.drawsSuggestionsInCmux else { return nil }
        return pane.visibleTab?.browserID
    }

    func send(_ action: ChromiumHostSuggestionAction, token: Int64, row: Int, browser: Int32) {
        pane?.runtime.shim?.suggestions.send(action, token: token, row: row, browser: browser)
    }
}
