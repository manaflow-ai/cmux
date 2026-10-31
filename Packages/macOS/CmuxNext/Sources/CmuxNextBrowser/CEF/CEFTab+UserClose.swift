import Foundation

/// A person's close of a Chromium tab runs the page's beforeunload first, as
/// in Chrome. Chromium's own beforeunload dialog never shows (it is app-modal
/// and its Stay button sent `-cancelTerminate:` to cmux's NSApp, the
/// 2026-10-20 nightly crash): the shim hands every question to the tab
/// (`OnBeforeUnloadDialog`, CEFShim/src/shim_client.mm), which asks in a cmux
/// dialog over the page (`BrowserPromptKind.beforeUnload`). Leave lets
/// Chromium close the page; BEFORE_CLOSE then asks for the tab's close
/// (`browserDidClose`). Stay keeps the tab as it was. A page that hangs in
/// its handler is closed by Chromium's own beforeunload timeout.
extension CEFTab: BrowserUserClosing {
    public func beginUserClose() -> Bool {
        // A page not created yet, or whose renderer ended, has no handler to run.
        guard !isClosed, let browserID, let shim = runtime.shim, state.processExit == nil else { return false }
        // A second close while the page asks: the question stays, and so does the tab.
        if asksBeforeUnload { return true }
        return shim.tryClose(browserID) == 0
    }

    /// The page asks before it unloads (a close, a navigation or a reload).
    /// A hidden tab comes forward first, as in Chrome, so the person sees the question.
    func beforeUnloadAsked(token: Int32, isReload: Bool) {
        let runtime = runtime
        if host.visibleTab !== self { emit(.activate) }
        // A closed tab answers Leave at once (`BrowserPrompt.dismissalResponse`).
        enqueuePrompt(.beforeUnload(isReload: isReload), origin: committedURL?.absoluteString ?? "") { response in
            _ = runtime.shim?.beforeUnloadReply(token, response == .accept ? 1 : 0)
        }
    }

    /// Chromium ended the question (renderer gone, page navigated or closed):
    /// it goes away; the shim already forgot its token, so the answer is ignored.
    func beforeUnloadDismissed() {
        for prompt in pendingPrompts where prompt.kind.isBeforeUnload { prompt.respond(.cancel) }
    }

    /// The page's beforeunload question shows now.
    var asksBeforeUnload: Bool {
        pendingPrompts.contains { $0.kind.isBeforeUnload && !$0.isResolved }
    }
}
