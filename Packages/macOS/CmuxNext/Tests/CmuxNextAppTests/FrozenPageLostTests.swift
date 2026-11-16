import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/44019, the app side: a hidden WebKit page frozen by
/// `BrowserHibernation` (`-[WKWebView _suspendPage:]`) whose web process then ended can never run again,
/// and WebKit raised on every call into it, a show's reload included. The planner discards it like a
/// hibernated page instead, and showing it restores its page in a new web view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct FrozenPageLostTests {
    @Test func aFrozenPageWhoseProcessEndedIsDiscardedAndRestoresWhenShown() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        // The app's own freezer: real WebKit suspends, not the rig's recorders.
        rig.hibernation.freezer = { $0 as? any BrowserFreezing }
        let keys = try await rig.pages(["lost", "other"])
        let key = keys[0]
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        try await rig.until("the hidden page freezes") { rig.hibernation.frozen.contains(key) && page.isFrozen }
        guard case .pids(let pids) = page.contentProcesses, let pid = pids.first else {
            Issue.record("the frozen page has no web process")
            return
        }
        #expect(kill(pid, SIGKILL) == 0)
        try await rig.until("the lost page is discarded") { rig.services.cache.browsers[key]?.tab is HibernatedBrowserTab }
        #expect(!rig.hibernation.frozen.contains(key))

        rig.show(key, order: keys)
        try await rig.until("the page restores in a new web view") {
            guard let tab = rig.services.cache.browsers[key]?.tab as? WebKitTab, tab !== page else { return false }
            return (try? await tab.evaluate("document.title", world: .page, gesture: .agent)) == .string("lost")
        }
    }
}
