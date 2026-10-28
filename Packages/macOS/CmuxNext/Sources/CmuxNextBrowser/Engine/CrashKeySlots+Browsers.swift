public import CmuxNextWakeups

extension CrashKeySlots {
    /// Names how many of `tabs` (the app's open browser pages) are live Chromium tabs and live WebKit pages in the
    /// crash-key page; a hibernated or deferred stand-in is neither. One pass over the open
    /// pages, run when the app adds, replaces or closes one.
    public func noteBrowsers(in tabs: some Sequence<any BrowserTab>) {
        var chromium = 0, webKit = 0
        for tab in tabs {
            if tab is CEFTab { chromium += 1 } else if tab is WebKitTab { webKit += 1 }
        }
        noteBrowsers(chromium: chromium, webKit: webKit)
    }
}
