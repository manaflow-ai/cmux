public import Foundation

/// A hidden Chromium page frozen through the page lifecycle: its timers, tasks and rendering stop
/// until it thaws. On cmux14 this cut a hidden renderer's energy by about 90 %.
///
/// From fork API 29 through `WebContents::SetPageFrozen` (`cmux_shim_tab_set_frozen`), which opens
/// no DevTools session, so the tab's renderer stays shareable; it freezes hidden pages only.
/// Before, through DevTools `Page.setWebLifecycleState`.
extension CEFTab: BrowserFreezing {
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        guard let browserID, !isClosed, let shim = runtime.shim else { return false }
        if runtime.forkFeatures.rendererPaths, let setFrozen = shim.tabSetFrozen { return setFrozen(browserID, frozen ? 1 : 0) == 1 }
        // Sent now, not from a Task: an agent call queued right after a thaw must not reach a frozen page.
        // No one waits for the reply (the runtime drops a reply without a waiter).
        return shim.devToolsCall(browserID, "Page.setWebLifecycleState", CEFDevToolsResult.params(["state": frozen ? "frozen" : "active"])) != 0
    }

    /// The spare window's placeholder made with no renderer (`CEFPaneHost.placeholderHasNoRenderer`), as
    /// Chrome makes restored tabs (`chrome/browser/ui/browser_tabrestore.cc`, `kNoRendererProcess`):
    /// nothing runs in it, so it is never frozen.
    var isRendererlessPlaceholder: Bool { host.placeholderHasNoRenderer && host.placeholder === self }

    /// Freezes a page that is never shown (the spare window's about:blank placeholder, on a fork with no
    /// renderer-less placeholder) through DevTools
    /// `Page.setWebLifecycleState`, which hides it to Chromium first (`WasHidden`): the fork's
    /// `cmux_shim_tab_set_frozen` freezes only pages Chromium already counts hidden, and
    /// `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser. Unfrozen, the
    /// placeholder counted visible and ran rAF at ~98/s at idle (fleet probe 4e065838, macOS 27). It is
    /// never thawed: a take closes it on the next turn (`CEFPaneHost.closeSparePlaceholder`).
    func freezeNeverShownPage(_ browser: Int32) {
        guard let shim = runtime.shim else { return }
        _ = shim.devToolsCall(browser, "Page.setWebLifecycleState", CEFDevToolsResult.params(["state": "frozen"]))
    }
}

/// Chrome's in-place discard (Memory Saver): a hidden page's renderer and document go and its tab
/// stays, `WebContents::Discard` (content/public/browser/web_contents.h) through the fork's
/// `cmux_shim_tab_discard` (p13-webui-018).
extension CEFTab {
    /// Discards the hidden page in place: the tab keeps its browser, window slot, NavigationEntry and
    /// session storage, and Chromium reloads the entry when the page shows. Makes no call into the page.
    ///
    /// - Returns: False when nothing was discarded (no export, host mode, no browser, closed, or
    ///   Chromium refused): the caller closes the page instead.
    @discardableResult
    public func discard() -> Bool {
        guard let browserID, !isClosed, let discard = runtime.shim?.tabDiscard, discard(browserID) == 1 else { return false }
        isDiscardedInPlace = true
        return true
    }

    /// Loads `url`, except the URL of the entry ``discard()`` emptied (as `.address` last set it): that
    /// sends nothing, because Chromium reloads the entry itself when the page shows, with its PageState
    /// and `document.wasDiscarded` (`WebContentsImpl::WasShown` -> `NavigationControllerImpl::SetActive`
    /// -> `LoadIfNecessary`, content/browser/renderer_host/navigation_controller_impl.cc).
    public func loadRestoringDiscard(_ url: URL) {
        if isDiscardedInPlace, !isClosed, (state.url ?? committedURL) == url { return }
        load(url)
    }
}
