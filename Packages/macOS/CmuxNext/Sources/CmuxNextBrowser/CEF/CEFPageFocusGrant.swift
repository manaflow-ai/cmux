/// The one place cmux gives a Chromium page, or its docked DevTools, keyboard focus (issue #24913).
///
/// At the pinned fork (API 24) a page shows in a child window, and CEF's `SetFocus(true)` makes that
/// window key: one key-window change, which walks both windows' view trees and activates the input
/// method (10 s stalls on macOS 14, 15 and 26 in the fuzzer). With fork API 30
/// (`cmux_browser_set_embedder_active`) page focus becomes an active flag plus cmux's own first
/// responder, and no page window is ever key: that switch replaces this type's body, and no caller.
///
/// Callers: `CEFTab.grantFocus` and `CEFTab.setFocused(false)` (the page), and
/// `CEFDevToolsController.setFocused` (docked DevTools).
nonisolated struct CEFPageFocusGrant {
    /// The loaded shim; nil before CEF starts (every call then does nothing).
    let shim: CEFShimLibrary?

    /// Gives (`true`) or takes (`false`) the page's focus. Giving it makes the page window key today.
    func page(_ browser: Int32, focused: Bool) {
        shim?.setFocus(browser, focused ? 1 : 0)
    }

    /// Gives or takes the focus of the docked DevTools of the page `browser`.
    func devTools(of browser: Int32, focused: Bool) {
        shim?.devToolsSetFocus(browser, focused ? 1 : 0)
    }
}
