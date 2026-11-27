/// A tab whose engine can reload past its caches: Chrome's Hard Reload
/// (Cmd-Shift-R, `browserHardReload`). WebKit reloads from origin; Chromium
/// reloads its entry ignoring the cache, as Chrome does.
@MainActor
public protocol BrowserCacheBypassingReload: AnyObject {
    /// Reloads the page, fetching it and every subresource again from the server.
    func reloadBypassingCache()
}
