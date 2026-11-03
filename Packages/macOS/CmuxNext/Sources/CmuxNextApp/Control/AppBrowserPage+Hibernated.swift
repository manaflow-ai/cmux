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
    /// placeholder, else the page restored for it (woken in the background,
    /// awaited for at most `within`). Nil when it did not come back in time.
    static func awakePage(_ key: String, page: any BrowserTab, cache: TabContentCache,
                          within: Duration) async -> (any BrowserTab)? {
        guard page is HibernatedBrowserTab else { return page }
        // Restarts the tab's hidden clock: it does not go back to sleep while the agent works.
        cache.hibernation?.noteAgentUse(key)
        _ = cache.hibernation?.wake(key)
        let woke = try? await ControlDeadline.shared.run(method: "browser.wake", deadline: .now + within) { @MainActor in
            // Every restore installs a page (`pageInstalls`), which wakes this wait.
            for await live in ObservationStream({ _ = cache.pageInstalls.revision; return isLive(cache.existingBrowser(key)?.tab) }) where live {
                return true
            }
            return false
        }
        guard woke == true, let live = cache.existingBrowser(key)?.tab, isLive(live) else { return nil }
        cache.hibernation?.noteAgentUse(key)
        return live
    }

    private static func isLive(_ page: (any BrowserTab)?) -> Bool {
        guard let page else { return false }
        return !(page is HibernatedBrowserTab)
    }

    static var wakeFailed: ControlError {
        ControlError(code: "unavailable", message: BrowserPageStrings.wakeFailed)
    }
}
