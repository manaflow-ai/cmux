@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextHibernation
import CmuxNextSettings
import Foundation
import Observation
import Testing
import CmuxNextWakeups

/// Browser hibernation follows each page's sound as Chrome's page node follows its audible bit
/// (`PageNode::IsAudible`, `GetTimeSinceLastAudibleChange`): the tab's own audible bit, observed
/// with no poll from the moment the page is mounted. When a hidden page's sound ends, the
/// hibernation plans again: the recently audible rule (`DiscardRule.recentlyAudible`) keeps the
/// page for a minute, the minute's end is the one hibernation deadline, and once it is over the
/// page hibernates. All of it only with `recentlyAudibleProtection` on (an `AudibleHistory`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ContentDiscardPlannerAudioWatchTests {
    final class FakeNow {
        var now = ContinuousClock.now
    }

    /// A mock page installed as a tab, shown, then hidden.
    private func hiddenMockPage(_ rig: NeighborTabsWakeTests.Rig, playing: Bool) throws -> (key: String, tab: MockBrowserTab) {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/listen"), origin: .user))
        let key = tab.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(tab, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        if playing { tab.simulate(.mediaChanged(BrowserMediaState(title: "Song", isPlaying: true))) }
        rig.services.cache.withdraw(key, by: rig.pane)
        try #require(rig.services.cache.phase(of: key) == .mountedHidden)
        return (key, tab)
    }

    /// A loaded WebKit page, hidden, that plays a song and then stops, with hibernation after
    /// `minutes`: it is kept for its sound, then for the minute after.
    private func pageWhoseSoundEnded(_ rig: NeighborTabsWakeTests.Rig, minutes: Double) async throws -> (key: String, page: WebKitTab) {
        let key = try #require(try await rig.pages(["song"]).first)
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        page.apply(.mediaChanged(BrowserMediaState(title: "Song", isPlaying: true)))
        let audible = try #require(rig.hibernation.audible)
        try await rig.until("the sound is seen") { audible.isWatchedAudible(key) == true }
        rig.hibernation.apply(BrowserHibernationSetting(mode: .minutes(minutes), freezeSeconds: nil))
        #expect(rig.hibernation.exemptions[key] == .audio, "a hidden page whose tab plays is kept with no probe")

        page.apply(.mediaChanged(nil))
        try await rig.until("the end of the sound replans") { rig.hibernation.exemptions[key] == .recentlyAudible }
        return (key, page)
    }

    @Test func aHiddenPageHibernatesOnceTheMinuteAfterItsSoundIsOver() async throws {
        let clock = FakeNow()
        let rig = try NeighborTabsWakeTests.Rig(freezes: false, audible: AudibleHistory(now: { clock.now }, mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let (key, _) = try await pageWhoseSoundEnded(rig, minutes: 0.001)
        let next = try #require(rig.hibernation.nextCheck, "the minute's end armed no deadline")
        #expect(next > 59 && next <= 60.001, "the one deadline is the minute's end: \(next)")
        #expect(!(rig.services.cache.browsers[key]?.tab is HibernatedBrowserTab), "the page hibernated within its minute")

        clock.now += .seconds(61)
        rig.hibernation.replan()
        try await rig.until("the page hibernates") { rig.services.cache.browsers[key]?.tab is HibernatedBrowserTab }
        #expect(rig.hibernation.exemptions[key] == nil)
    }

    /// The minute is over and the page's own timeout is far: the plan keeps it for no reason, so
    /// `debug.surfaces` no longer says it is recently audible.
    @Test func aLaterTimeoutDropsTheEndedReason() async throws {
        let clock = FakeNow()
        let rig = try NeighborTabsWakeTests.Rig(freezes: false, audible: AudibleHistory(now: { clock.now }, mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let (key, _) = try await pageWhoseSoundEnded(rig, minutes: 30)
        let atEnd = try #require(rig.hibernation.nextCheck)
        #expect(atEnd > 1_000, "a page due much later is looked at again at its timeout, not at the minute's end: \(atEnd)")

        clock.now += .seconds(61)
        rig.hibernation.replan()
        #expect(rig.hibernation.exemptions[key] == nil, "the ended reason stayed: \(String(describing: rig.hibernation.exemptions[key]))")
        let next = try #require(rig.hibernation.nextCheck)
        #expect(next > 1_000, "the next look is the page's own timeout: \(next)")
    }

    @Test func aPageThatNeverPlayedIsNotProtected() throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false, audible: AudibleHistory(mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let (key, _) = try hiddenMockPage(rig, playing: false)
        let entry = try #require(rig.services.cache.browsers[key])
        let facts = rig.hibernation.candidate(key, entry: entry, hiddenFor: 0)
        #expect(!facts.isAudible)
        #expect(facts.secondsSinceAudible == nil)
    }

    /// With the feature off nothing is watched and no candidate carries a sound fact: the plans
    /// are those from before the rule.
    @Test func theFeatureOffAddsNoSoundFacts() throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false)
        defer { rig.close() }
        #expect(rig.hibernation.audible == nil)
        let (key, _) = try hiddenMockPage(rig, playing: true)
        let entry = try #require(rig.services.cache.browsers[key])
        let facts = rig.hibernation.candidate(key, entry: entry, hiddenFor: 0)
        #expect(!facts.isAudible, "the tab's report kept the page with the feature off")
        #expect(facts.secondsSinceAudible == nil)
    }

    /// A page whose sound starts and ends while it shows (a page swapped in on screen too) is
    /// followed from its mount, not from a show.
    @Test func aShownPageIsFollowedFromItsMount() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false, audible: AudibleHistory(mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/shown"), origin: .user))
        let key = tab.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(tab, for: key)
        let audible = try #require(rig.hibernation.audible)
        #expect(audible.isWatchedAudible(key) == false, "a mounted page is not watched")
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Song", isPlaying: true)))
        try await rig.until("the sound is seen") { audible.isWatchedAudible(key) == true }
        tab.simulate(.mediaChanged(nil))
        try await rig.until("the end of the sound is seen") { audible.isWatchedAudible(key) == false }
        #expect(audible.secondsSinceAudible(key) != nil)
    }

    /// The watch follows the audible bit only: a load tick or a title on a watched page is no change.
    @Test func aTitleOrLoadTickIsNoAudibleChange() async throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/quiet"), origin: .user))
        let history = AudibleHistory(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        var changes = 0
        history.onEnded = { _ in changes += 1 }
        history.watch("quiet", tab) { [weak tab] in tab?.isAudible == true }
        let (flips, flipped) = AsyncStream<Void>.makeStream()
        withObservationTracking { _ = tab.isAudible } onChange: { flipped.yield() }
        tab.simulate(.titleChanged("Quiet"))
        tab.simulate(.progress(0.5))
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: false, isVideo: true)))
        flipped.finish()
        var observed = 0
        for await _ in flips { observed += 1 }
        #expect(observed == 0, "the audible bit changed on a title, a load tick or silent media")
        #expect(changes == 0)
        #expect(history.isWatchedAudible("quiet") == false)
    }

    /// A probe stamps the page's last sound only for sound the person hears: Web Audio or unmuted
    /// media, not a paused video in Picture in Picture.
    @Test func aProbeHearsWebAudioAndNotAFloatingPausedVideo() async {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/game"), origin: .user))
        tab.evaluationResult = .string(#"{"media":false,"sound":false,"form":false,"audio":true}"#)
        #expect(await BrowserHibernation.probe(tab).audible, "a running Web Audio context was not heard")

        tab.evaluationResult = .string(#"{"media":true,"sound":false,"form":false,"audio":false}"#)
        tab.simulate(.mediaChanged(BrowserMediaState(title: "Clip", isPlaying: false, isVideo: true, isPictureInPicture: true)))
        let floating = await BrowserHibernation.probe(tab)
        #expect(floating.playingMedia, "a floating video still keeps the page")
        #expect(!floating.audible, "a paused floating video was heard")

        tab.evaluationResult = .string(#"{"media":true,"sound":true,"form":false,"audio":false}"#)
        #expect(await BrowserHibernation.probe(tab).audible, "unmuted media that plays was not heard")
    }

    /// The freeze probe of a hidden page that plays Web Audio stamps its last sound, so the minute
    /// after its context stops keeps it (the tab's media report covers media elements only).
    @Test func theFreezeProbeRecordsWebAudio() async throws {
        let clock = FakeNow()
        let rig = try NeighborTabsWakeTests.Rig(freezes: true, audible: AudibleHistory(now: { clock.now }, mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/synth"), origin: .user))
        tab.evaluationResult = .string(#"{"media":false,"sound":false,"form":false,"audio":true}"#)
        let key = tab.id.rawValue
        rig.recorders[key] = NeighborTabsWakeTests.Recorder()
        rig.keys.append(key)
        rig.services.cache.install(tab, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        rig.services.cache.withdraw(key, by: rig.pane)
        let audible = try #require(rig.hibernation.audible)
        try await rig.until("the freeze probe hears the page") { audible.secondsSinceAudible(key) != nil }

        clock.now += .seconds(30)
        let entry = try #require(rig.services.cache.browsers[key])
        let facts = rig.hibernation.candidate(key, entry: entry, hiddenFor: 3_600)
        #expect(DiscardRule.audioProtectionLeft(facts) == 30, "30 s after the last sound the page has 30 s left")
    }

    /// A closed page leaves no sound history or watch behind.
    @Test func forgetDropsTheHistory() async throws {
        let rig = try NeighborTabsWakeTests.Rig(freezes: false, audible: AudibleHistory(mainWork: MainWorkScheduler(budget: MainFrameBudget())))
        defer { rig.close() }
        let (key, _) = try hiddenMockPage(rig, playing: true)
        let audible = try #require(rig.hibernation.audible)
        try await rig.until("the sound is seen") { audible.secondsSinceAudible(key) != nil }
        rig.hibernation.forget(key)
        #expect(audible.secondsSinceAudible(key) == nil)
        #expect(audible.isWatchedAudible(key) == nil)
    }
}
