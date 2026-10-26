import Foundation

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
    /// Discards the hidden page in place. The tab keeps its browser id, window slot, NavigationEntry
    /// (with its PageState) and session storage, so ``loadDiscarded(_:)`` brings the page back in the
    /// same browser. Makes no call into the page.
    ///
    /// - Returns: False when nothing was discarded: the fork has no export, the tab is closed or has
    ///   no browser yet, or Chromium still counts the page visible. The caller then closes the page.
    @discardableResult
    public func discard() -> Bool {
        guard let browserID, !isClosed, let discard = runtime.shim?.tabDiscard else { return false }
        return discard(browserID) == 1
    }

    /// Loads `url` in a tab ``discard()`` emptied. The URL its last entry committed reloads that entry
    /// in place, as Chromium restores a discarded tab (`NavigationControllerImpl::LoadIfNecessary`,
    /// content/browser/renderer_host/navigation_controller_impl.cc): the same entry, its PageState and
    /// session storage, and the document sees `document.wasDiscarded`. Another URL is a new navigation.
    public func loadDiscarded(_ url: URL) {
        guard browserID != nil, !isClosed, committedURL == url else { return load(url) }
        reload()
    }
}
