import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Observation

/// Agent operations on a hibernated tab (`cmux browser …`, MCP, the browser
/// REPL). A hibernated tab keeps only its URL, title, favicon and a picture;
/// its engine page is closed. `state` answers from the placeholder and does
/// not wake it. Navigation (navigate, back, forward, reload) goes to the
/// placeholder, which wakes the page and applies the step once its history
/// is back (`HibernatedBrowserTab.onWake`), so the page loads once. Every
/// other operation wakes the page in the background (no focus, nothing
/// shown), waits for it, bounded, and then acts on the live page. Agents
/// never get a "not running" or "closed" error only because the tab slept.
extension AppBrowserPage {
    /// Whether `operation` can be answered by a hibernated placeholder.
    static func answersWhileHibernated(_ operation: BrowserPageOperation) -> Bool {
        switch operation {
        case .state, .navigate, .back, .forward, .reload: true
        case .evaluate, .evaluateAsync, .screenshot, .cookies, .input, .upload: false
        }
    }

    /// The `state` result: `hibernated` is true for a placeholder, so an
    /// agent knows a later read wakes the page.
    static func stateResult(_ page: any BrowserTab) -> JSONValue {
        var members: [String: JSONValue] = [
            "url": .string(page.state.url?.absoluteString ?? "about:blank"),
            "title": .string(page.state.title ?? ""),
        ]
        if page is HibernatedBrowserTab { members["hibernated"] = .bool(true) }
        return .object(members)
    }

    /// The live page of tab `key`: `page` itself unless it is a hibernated
    /// placeholder or a restored page the launch defers, else the page made
    /// for it (woken or started in the background, awaited for at most
    /// `within`). Nil when it did not come in time or the wake was deferred
    /// (``wakeError(_:cache:)`` tells which).
    static func awakePage(_ key: String, page: any BrowserTab, cache: TabContentCache,
                          within: Duration) async -> (any BrowserTab)? {
        if page is DeferredBrowserTab {
            // A command starts Chromium at once (`.automation`); a crash deferral waits for the person.
            guard cache.startLaunchDeferred(key) else { return page }
            return await installedLivePage(key, cache: cache, method: "browser.start", owner: "browser.page.start", within: within)
        }
        guard page is HibernatedBrowserTab else { return page }
        // Restarts the tab's hidden clock: it does not go back to sleep while the agent works.
        cache.hibernation?.noteAgentUse(key)
        // An agent's wake is admitted as Chrome admits a background tab load (`WakeAdmission`): it may wait for a slot or be deferred.
        if case .deferred(_)? = cache.hibernation?.wake(key, by: .automation) { return nil }
        guard let live = await installedLivePage(key, cache: cache, method: "browser.wake", owner: "browser.page.wake", within: within) else { return nil }
        cache.hibernation?.noteAgentUse(key)
        return live
    }

    /// Tab `key`'s live page once the cache installed one, nil after `within` or once its queued wake is deferred.
    private static func installedLivePage(_ key: String, cache: TabContentCache, method: String, owner: String,
                                          within: Duration) async -> (any BrowserTab)? {
        let installed = try? await ControlDeadline.shared.run(method: method, deadline: .now + within) { @MainActor in
            // Every restore and start installs a page (`pageInstalls`), which wakes this wait.
            await ControlConditionWait(on: cache.mainWork, owner: owner).until {
                _ = cache.pageInstalls.revision
                return isLive(cache.existingBrowser(key)?.tab) || cache.hibernation?.deferral(of: key) != nil
            }
        }
        guard installed == true, let live = cache.existingBrowser(key)?.tab, isLive(live) else { return nil }
        return live
    }

    private static func isLive(_ page: (any BrowserTab)?) -> Bool {
        guard let page else { return false }
        return !(page is HibernatedBrowserTab) && !(page is DeferredBrowserTab)
    }

    static var wakeFailed: ControlError {
        ControlError(code: "unavailable", message: BrowserPageStrings.wakeFailed)
    }

    /// Why tab `key`'s page did not wake: `deferred` with the ``WakeAdmission/Deferral`` when the admission
    /// held its wake back (memory pressure, low free memory), else ``wakeFailed``.
    static func wakeError(_ key: String, cache: TabContentCache) -> ControlError {
        guard let deferral = cache.hibernation?.deferral(of: key) else { return wakeFailed }
        return ControlError(code: "deferred", message: BrowserPageStrings.wakeDeferred, data: ["reason": .string(deferral.rawValue)])
    }
}
