@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Testing

/// Browser hibernation follows each page's sound as Chrome's page node follows its audible bit
/// (`PageNode::IsAudible`, `GetTimeSinceLastAudibleChange`): the tab's own media report, observed
/// with no poll. When a hidden page's sound ends, its candidate counts from that moment, so the
/// planner's recently audible rule (`DiscardRule.recentlyAudible`) keeps it for a minute and the
/// minute's end joins the one hibernation deadline.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ContentDiscardPlannerAudioWatchTests {
    /// A mock page installed as a tab, shown, then hidden.
    private func hiddenPage(_ rig: NeighborTabsWakeTests.Rig, playing: Bool) throws -> (key: String, tab: MockBrowserTab) {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/listen")))
        let key = tab.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(tab, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        if playing { tab.simulate(.mediaChanged(BrowserMediaState(title: "Song", isPlaying: true))) }
        rig.services.cache.withdraw(key, by: rig.pane)
        try #require(rig.services.cache.phase(of: key) == .mountedHidden)
        return (key, tab)
    }

    @Test func theEndOfAHiddenPagesSoundStartsItsMinute() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        let (key, tab) = try hiddenPage(rig, playing: true)
        try await rig.until("the sound is seen") { rig.hibernation.audible.isWatchedAudible(key) == true }
        let entry = try #require(rig.services.cache.browsers[key])
        #expect(rig.hibernation.candidate(key, entry: entry, hiddenFor: 0).isAudible)

        tab.simulate(.mediaChanged(nil))
        try await rig.until("the end of the sound is seen") { rig.hibernation.audible.isWatchedAudible(key) == false }
        let facts = rig.hibernation.candidate(key, entry: entry, hiddenFor: 0)
        #expect(!facts.isAudible)
        let since = try #require(facts.secondsSinceAudible, "the end of the sound was not recorded")
        #expect(since >= 0 && since < 10, "counted from the end of the sound: \(since)")
        let eligibility = ContentDiscardPlanner().eligibility(of: facts, setting: .fallback, for: .urgent)
        #expect(eligibility.reasons.contains(.recentlyAudible))
    }

    @Test func aPageThatNeverPlayedIsNotProtected() throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        let (key, _) = try hiddenPage(rig, playing: false)
        let entry = try #require(rig.services.cache.browsers[key])
        let facts = rig.hibernation.candidate(key, entry: entry, hiddenFor: 0)
        #expect(!facts.isAudible)
        #expect(facts.secondsSinceAudible == nil)
    }

    /// A closed page leaves no sound history or watch behind.
    @Test func forgetDropsTheHistory() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        let (key, _) = try hiddenPage(rig, playing: true)
        try await rig.until("the sound is seen") { rig.hibernation.audible.secondsSinceAudible(key) != nil }
        rig.hibernation.forget(key)
        #expect(rig.hibernation.audible.secondsSinceAudible(key) == nil)
        #expect(rig.hibernation.audible.isWatchedAudible(key) == nil)
    }
}
