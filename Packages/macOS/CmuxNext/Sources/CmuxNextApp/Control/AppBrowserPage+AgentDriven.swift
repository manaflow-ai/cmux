import CmuxNextBrowser
import CmuxNextControl
import Foundation

/// The first time an agent touches a tab, a saved password Chromium filled
/// before may still sit in the page, or in a window its script can reach
/// through `window.opener` or a `window.open` handle: turning fill off does
/// not take it back. The page is rebuilt first (`rebuildForAgent`), and the
/// operation answers "retry" so it runs on the new page
/// (plans/cmux-next/browser.md, "Browser import: passwords and security").
extension AppBrowserPage {
    /// Marks tab `tabID` and its popups agent-driven; true when its live
    /// Chromium page was not marked yet, whatever it shows (an `about:blank`
    /// tab a page opened shares its opener's origin and keeps `window.opener`).
    /// A hibernated or deferred placeholder holds no document: the page that
    /// replaces it is marked when it installs.
    static func markAgentDriven(_ tabID: String, services: AppServices) -> Bool {
        let page = services.cache.existingBrowser(tabID)?.tab
        let stale = page.map { !$0.isAgentDriven && $0.engineKind == .cef && !($0 is HibernatedBrowserTab) && !($0 is DeferredBrowserTab) } ?? false
        services.cache.markAgentDriven(tabID)
        // A popup's opener is the old page: once that is rebuilt, the tab's script reaches the popup no more.
        for popup in services.popups.pages(openedBy: tabID) { popup.markAgentDriven() }
        return stale
    }

    /// Rebuilds a stale page; only `state` (which reads no page content) goes on.
    static func rebuildStale(_ stale: Bool, tabID: String, for operation: BrowserPageOperation, services: AppServices) throws {
        guard stale else { return }
        services.cache.rebuildForAgent(tabID)
        guard operation != .state else { return }
        throw ControlError(code: "unavailable", message: "The browser page reopened so no saved password stays filled in it; retry")
    }
}
