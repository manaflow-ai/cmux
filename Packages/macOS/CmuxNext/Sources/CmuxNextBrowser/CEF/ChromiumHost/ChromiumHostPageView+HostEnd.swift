import AppKit

extension ChromiumHostPageView {
    /// The Chromium Host ended (``CEFPaneHost/hostEnded()``): in the same turn the view drops all the host
    /// gave it, while the pane's sad tab covers it. Its context, its cursor and tooltip, its
    /// suggestions, the keys it held for KEY_UNHANDLED, its fullscreen, pointer and keyboard locks (the cursor
    /// is free again), and the focused field with its composition, so secure event input goes off with a
    /// password field that ended with the host.
    func hostEnded() {
        show(contextID: 0)
        (pageCursor, pageTooltip) = (nil, nil)
        suggestions.hostEnded()
        keyDowns.removeAll()
        exclusiveAccess.hostEnded()
        #if DEBUG || CMUX_BENCH_HOOKS
        applyTextInputState(ChromiumHostTextInputState())
        #endif
    }
}
