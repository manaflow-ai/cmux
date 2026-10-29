import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextSettings
import Foundation
import Testing

/// `cmux browser`, MCP and the browser REPL on a hibernated tab: a read of the
/// page's address and title answers from the placeholder without waking it;
/// anything that needs the page (a script, a screenshot, cookies) wakes it in
/// the background and runs on the restored page, never failing with the
/// placeholder's "closed". Real WebKit pages through the app's hibernation.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HibernatedTabAgentWakeTests {
    @Test func stateAnswersFromTheHibernatedTabWithoutWakingIt() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("asleep", body: "<p>asleep</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        let placeholder = try #require(rig.services.cache.existingBrowser(key)?.tab)

        #expect(AppBrowserPage.answersWhileHibernated(.state))
        let state = AppBrowserPage.stateResult(placeholder)
        #expect(state["title"] == .string("asleep"))
        #expect(state["url"]?.stringValue?.hasSuffix("asleep.html") == true)
        #expect(state["hibernated"] == .bool(true), "an agent cannot tell the tab is hibernated")
        #expect(rig.isHibernated(key), "reading the address woke the page")
    }

    @Test func aScriptOnAHibernatedTabWakesItAndRuns() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("wake", body: "<p id='p'>wake me</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        let placeholder = try #require(rig.services.cache.existingBrowser(key)?.tab)
        // What failed before: the placeholder has no document.
        await #expect(throws: (any Error).self) { try await placeholder.evaluate("1", world: .page, gesture: .agent) }
        #expect(!AppBrowserPage.answersWhileHibernated(.evaluate("1")))

        let live = try #require(await AppBrowserPage.awakePage(key, page: placeholder, cache: rig.services.cache, within: .seconds(15)),
                                "the hibernated page did not wake for the agent")
        #expect(!(live is HibernatedBrowserTab))
        #expect(!rig.isHibernated(key))
        #expect(rig.services.cache.phase(of: key) != .mountedVisible, "waking for an agent showed the tab")
        try await rig.until("the restored page loads") {
            (try? await live.evaluate("document.readyState === 'complete' && document.getElementById('p').textContent", world: .page, gesture: .agent))
                == .string("wake me")
        }
    }

    @Test func aLivePageIsUsedAsItIs() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await rig.page("awake", body: "<p>awake</p>")
        let key = page.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(page, for: key)
        let live = await AppBrowserPage.awakePage(key, page: page, cache: rig.services.cache, within: .seconds(1))
        #expect(live === page)
    }
}

extension HibernatedTabAgentWakeTests {
    /// Under critical memory pressure a hidden page hibernates at once; one an agent just woke
    /// must stay up for the agent's next call, or every second call would find it asleep again.
    @Test func aPageAnAgentWokeStaysAwakeForItsNextCall() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await rig.hide(rig.page("busy", body: "<p>busy</p>"))
        try await rig.until("the page hibernated") { rig.isHibernated(key) }
        let placeholder = try #require(rig.services.cache.existingBrowser(key)?.tab)
        let live = try #require(await AppBrowserPage.awakePage(key, page: placeholder, cache: rig.services.cache, within: .seconds(15)))
        rig.hibernation.replan()
        try await Task.sleep(for: .milliseconds(500)) // test-only: gives a wrongly started probe time to hibernate the page
        #expect(!rig.isHibernated(key), "the page an agent woke hibernated again before its next call")
        #expect(rig.hibernation.exemptions[key] == .agentDriving)
        #expect(rig.services.cache.existingBrowser(key)?.tab === live)
    }
}
