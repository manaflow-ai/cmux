import CmuxNextBrowser
import CmuxNextHistory
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation

/// CHROME-INTERNAL-PAGES routing on the person's paths (omnibar, New Tab
/// field, bookmarks): `chrome://history` and `chrome://bookmarks` show cmux's
/// own pages, `chrome://settings` opens Settings > Browser, Chromium's
/// password manager opens the Passwords page, `cmux://stashed` the Stashed Tabs page, every
/// other page is Chromium's.
/// Agent paths refuse these URLs before they get here (AgentURLPolicy).
/// `openBrowser` uses the same route (BrowserOpenPlan). A Mac Screen address
/// (`cmux://mac-screen`) opens the Mac Screen tab: it is no browser page.
@MainActor
enum ChromiumPageRouter {
    /// What a page load of `url` becomes: cmux's page for a page cmux shows
    /// itself, nil when Settings or the Passwords page opened instead (nothing
    /// to load), else `url`. A Mac Screen address opens its page tab in
    /// `pane` (else the active window's focused pane), connecting at once
    /// only for a person's input, and returns nil.
    static func routed(_ url: URL, services: AppServices, focus: Bool = true, in pane: PaneController? = nil) -> URL? {
        if let record = MacScreenRecord(url: url) {
            services.macScreenTabs.openAddress(record, in: pane, focus: focus)
            return nil
        }
        // Stashed Tabs is a top page, not a browser page: it opens instead, and nothing loads.
        if url.isStashedPage {
            _ = try? StashHandlers.show(services, focus: focus)
            return nil
        }
        switch ChromiumPageRoute(url) {
        case .cmuxPage(let page)?:
            return page
        case .browserSettings?:
            try? services.settingsWindow.show(section: .browser, focus: focus)
            return nil
        case .passwordsPage?:
            try? showPasswords(services, focus: focus)
            return nil
        case .chromium?, nil:
            return url
        }
    }

    /// The Passwords page tab in the active window, for `chrome://password-manager`.
    static func showPasswords(_ services: AppServices, focus: Bool) throws {
        guard let window = services.windows.active, services.pages.show(.passwords, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }
}
