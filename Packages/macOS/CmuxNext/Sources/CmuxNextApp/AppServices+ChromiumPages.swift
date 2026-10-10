import CmuxNextBrowser
import CmuxNextSettings
import Foundation

/// CHROME-INTERNAL-PAGES routing on the person's paths (omnibar, New Tab
/// field, bookmarks): `chrome://history` and `chrome://bookmarks` show cmux's
/// own pages, `chrome://settings` opens Settings > Browser, every other page
/// is Chromium's. Agent paths refuse these URLs before they get here
/// (AgentURLPolicy). `openBrowser` uses the same route (BrowserOpenPlan).
extension AppServices {
    /// What a page load of `url` becomes: cmux's page for a page cmux shows
    /// itself, nil when Settings opened instead (nothing to load), else `url`.
    func routedChromiumPage(_ url: URL, focus: Bool = true) -> URL? {
        switch ChromiumPageRoute(url) {
        case .cmuxPage(let page)?:
            return page
        case .browserSettings?:
            try? settingsWindow.show(section: .browser, focus: focus)
            return nil
        case .chromium?, nil:
            return url
        }
    }
}
