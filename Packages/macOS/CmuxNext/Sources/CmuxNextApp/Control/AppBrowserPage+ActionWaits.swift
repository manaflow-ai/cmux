import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import Foundation

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
            // The cache's page table is not observable; `pageInstalls` is
            // bumped by every install, so a page installed after the first
            // look wakes this wait (it waited out its bound before).
            await ControlConditionWait(on: cache.mainWork, owner: "browser.page.await_page").until {
                _ = cache.pageInstalls.revision
                return cache.existingBrowser(tabID) != nil
            }
        }
        guard found == true else { return nil }
        return services.cache.existingBrowser(tabID)?.tab
    }

    /// True once `page` has no pending navigation (at once when it has
    /// none), false after `within` (the action then runs anyway). A page
    /// with keyed waits (``BrowserPageWaiting``) is read again only when its
    /// load phase changes, never on a title or progress tick.
    static func awaitPendingNavigation(_ page: any BrowserTab, within: Duration, work: MainWorkScheduler) async -> Bool {
        guard page.state.isLoading else { return true }
        if let waiting = page as? any BrowserPageWaiting {
            return await waiting.when(phase: { !isLoading($0) }, timeout: within) != nil
        }
        let done = try? await ControlDeadline.shared.run(method: "browser.navigation", deadline: .now + within) { @MainActor in
            await ControlConditionWait(on: work, owner: "browser.page.await_navigation").until { !page.state.isLoading }
        }
        return done == true
    }

    /// Whether a page in `phase` still loads, as ``BrowserTabState/isLoading`` reads it.
    private static func isLoading(_ phase: BrowserLoadPhase) -> Bool {
        switch phase {
        case .provisional, .committed: true
        case .idle, .finished, .failed: false
        }
    }
}
