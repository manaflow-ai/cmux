import CmuxNextBrowser
import CmuxNextControl
import Foundation
import Observation

/// An agent's page action right after `cmux browser open` (cx-qncg): the
/// tab's page may not exist yet (Chromium makes pages asynchronously), and
/// its first navigation may still load. The action waits for both, bounded,
/// as the auto engine, Aside and ChatGPT do, instead of failing at once.
extension AppBrowserPage {
    /// How long an action waits for the page and for its pending navigation.
    static let actionWait: Duration = .seconds(15)

    /// The tab's page once the cache has one, nil after `within`.
    static func awaitPage(_ tabID: String, services: AppServices, within: Duration) async -> (any BrowserTab)? {
        if let page = services.cache.existingBrowser(tabID)?.tab { return page }
        let cache: TabContentCache = services.cache
        let found = try? await ControlDeadline.shared.run(method: "browser.page", deadline: .now + within) { @MainActor in
            for await present in Observations({ cache.existingBrowser(tabID) != nil }) where present { return true }
            return false
        }
        guard found == true else { return nil }
        return services.cache.existingBrowser(tabID)?.tab
    }

    /// True once `page` has no pending navigation (at once when it has
    /// none), false after `within` (the action then runs anyway).
    static func awaitPendingNavigation(_ page: any BrowserTab, within: Duration) async -> Bool {
        guard page.state.isLoading else { return true }
        let done = try? await ControlDeadline.shared.run(method: "browser.navigation", deadline: .now + within) { @MainActor in
            for await loading in Observations({ page.state.isLoading }) where !loading { return true }
            return false
        }
        return done == true
    }
}
