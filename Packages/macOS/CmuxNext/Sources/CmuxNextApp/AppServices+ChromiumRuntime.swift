import CmuxNextBrowser

// Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6).
extension AppServices {
    /// Follows the runtime download, and makes every "can Chromium open a
    /// tab?" check that finds the download pending ask for it at user
    /// priority (a tab, the palette or the CLI wanted Chromium now).
    func startChromiumRuntime() {
        let runtime = chromiumRuntime
        runtime.start(on: mainDeadlines)
        let browserTabs = cache.browserTabs
        let engineReason = browserTabs.cefUnavailable
        browserTabs.cefUnavailable = { [weak runtime] in
            let reason = engineReason()
            if reason?.isAwaitingDownload == true { runtime?.wanted() }
            return reason
        }
    }
}
