public import Foundation

/// A hidden Chromium page frozen through the page lifecycle: its timers, tasks and rendering stop
/// until it thaws. On cmux14 this cut a hidden renderer's energy by about 90 %.
///
/// From fork API 29 through `WebContents::SetPageFrozen` (`cmux_shim_tab_set_frozen`), which opens
/// no DevTools session, so the tab's renderer stays shareable; it freezes hidden pages only.
/// Before, through DevTools `Page.setWebLifecycleState`. The freeze is the second step after the hide
/// (``CEFTabNodeVisibility/setFrozen(_:of:)``).
extension CEFTab: BrowserFreezing {
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool { nodeVisibility.setFrozen(frozen, of: self) }

    /// The page its off-screen window shows: hidden to Chromium first when its node did not hide it
    /// (``CEFTabNodeVisibility/freezeShown(of:)``).
    public func freezeShownInOffScreenWindow() -> Bool { nodeVisibility.freezeShown(of: self) }

    /// The spare window's placeholder made with no renderer (`CEFPaneHost.placeholderHasNoRenderer`), as
    /// Chrome makes restored tabs (`chrome/browser/ui/browser_tabrestore.cc`, `kNoRendererProcess`):
    /// nothing runs in it, so it is never frozen.
    var isRendererlessPlaceholder: Bool { host.placeholderHasNoRenderer && host.placeholder === self }

    /// The spare window's placeholder that still has a renderer: an about:blank page that is never shown.
    /// It exists only while the fork pin (API 24) has no renderer-less placeholder
    /// (`cmux_shim_placeholder_supported`) or the `rendererlessSpareWindow` feature is off;
    /// with both, every spare's placeholder is ``isRendererlessPlaceholder`` and this is never true.
    var isFrozenSparePlaceholder: Bool { host.quietsPlaceholder && host.placeholder === self && !host.placeholderHasNoRenderer }

    /// Freezes a page that is never shown (``CEFTabNodeVisibility/freezeNeverShown(_:runtime:)``).
    /// It is never thawed: a take closes it on the next turn (`CEFPaneHost.closeSparePlaceholder`).
    func freezeNeverShownPage(_ browser: Int32) { CEFTabNodeVisibility.freezeNeverShown(browser, runtime: runtime) }
}

/// The tab's back-forward cache emptied while it is hidden (p07-memory-101): the fork's
/// `cmux_flush_back_forward_cache`, the tab's `BackForwardCache::Flush`
/// (content/public/browser/back_forward_cache.h). A fork without the call does nothing.
extension CEFTab: BrowserBackForwardCacheFlushing {
    /// Sends one flush for a hidden tab's browser. A tab the content lifecycle shows is never
    /// flushed: its Back is the person's next step. The answer is not read, since in host mode the
    /// call is a post to the Chromium Host.
    @discardableResult
    public func flushBackForwardCache() -> Bool {
        guard let browserID, !isClosed, isContentHidden, let flush = runtime.shim?.tabFlushBackForwardCache else { return false }
        _ = flush(browserID)
        return true
    }
}

/// Chrome's in-place discard (Memory Saver): a hidden page's renderer and document go and its tab
/// stays, `WebContents::Discard` (content/public/browser/web_contents.h) through the fork's
/// `cmux_shim_tab_discard`.
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
