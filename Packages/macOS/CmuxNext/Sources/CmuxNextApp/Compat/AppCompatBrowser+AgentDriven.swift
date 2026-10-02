import CmuxNextBrowser
import CmuxNextControl
import Foundation

/// The first time an agent touches a tab, a saved password Chromium filled
/// before may still sit in the page (or in a popup the tab opened, which its
/// script can reach): turning fill off does not take it back. Those pages
/// reload first; fill is off by then, and Chromium never restores a password
/// field's value on reload (plans/cmux-next/browser.md, "Browser import:
/// passwords and security").
extension AppCompatBrowser {
    /// Marks tab `tabID` and its popups agent-driven; returns the pages that
    /// were not marked yet and show a web page in Chromium.
    static func markAgentDriven(_ tabID: String, services: AppServices) -> [any BrowserTab] {
        let pages = [services.cache.existingBrowser(tabID)?.tab].compactMap { $0 } + services.popups.pages(openedBy: tabID)
        let unmarked = pages.filter { !$0.isAgentDriven }
        services.cache.markAgentDriven(tabID)
        for page in unmarked { page.markAgentDriven() }
        return unmarked.filter { $0.engineKind == .cef && ["http", "https"].contains($0.state.url?.scheme?.lowercased() ?? "") }
    }

    /// Reloads `stale`. Only `reload` (which reloads the page itself) and
    /// `state` (which reads no page content) go on; anything else, navigating
    /// away included (the page would keep its value in the back/forward
    /// cache), throws "retry" so it runs on the reloaded page.
    static func reloadStale(_ stale: [any BrowserTab], page: any BrowserTab, for operation: CompatBrowserOperation) throws {
        guard !stale.isEmpty else { return }
        switch operation {
        case .reload:
            for other in stale where other !== page { other.reload() }
        case .state:
            for other in stale { other.reload() }
        case .navigate, .back, .forward, .evaluate:
            for other in stale { other.reload() }
            throw ControlError(code: "unavailable", message: "The browser page reloaded so no saved password stays filled in it; retry")
        }
    }
}
