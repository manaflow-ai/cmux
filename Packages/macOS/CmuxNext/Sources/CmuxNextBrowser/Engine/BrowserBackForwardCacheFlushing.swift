/// Tabs whose engine keeps the pages behind Back and Forward alive (Chromium's back-forward cache).
/// Hidden-page memory saving (`BrowserHibernation`) empties a hidden tab's cache, as Chrome turns the
/// cache off on low memory (`BackForwardCacheMemoryControls`,
/// content/browser/renderer_host/back_forward_cache_impl.cc); a later Back loads the page again.
/// WebKit keeps its own page cache and gives it back under pressure itself.
public protocol BrowserBackForwardCacheFlushing: AnyObject {
    /// Evicts every cached page behind the tab's Back and Forward; the tab's own page stays.
    /// - Returns: False when nothing was asked: the page is closed, has no engine page yet, or shows.
    @discardableResult
    func flushBackForwardCache() -> Bool
}
