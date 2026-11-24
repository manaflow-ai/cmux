import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
@testable import CmuxNextBrowser
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/51079: a WebKit tab playing open.spotify.com "gets stuck and
/// stops working", more than once. Paused and hidden, the tab froze after 30 s (`browser.freezeHiddenTabs`):
/// the freeze probe kept only media that played. Its paused session stayed in macOS Now Playing, on the
/// media keys and in the tab's media menu, and each of those runs its Play in the page, which a frozen page
/// never runs, so the music never came back. A hidden page with a media session now stays awake; it still
/// freezes once the session ends, and may still be discarded (that ends the session with the page).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PausedMediaFreezeTests {
    private static let paused = BrowserMediaState(title: "Piano Trio No. 2", artist: "Felix Mendelssohn", isPlaying: false,
                                                  position: 353, duration: 673)

    @Test func aPausedMediaSessionKeepsThePageFromAFreeze() async {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://open.spotify.com")))
        tab.evaluationResult = .string(#"{"media":false,"form":false}"#)
        tab.simulate(.mediaChanged(Self.paused))
        let probe = await BrowserHibernation.probe(tab)
        #expect(probe.answered)
        #expect(!probe.playingMedia, "a paused session counted as playing")
        #expect(probe.mediaSession)
        #expect(probe.stopsWhenFrozen, "a paused media session froze")
        // A discard ends the session with the page: no keep reason of its own.
        #expect(probe.exemption == nil)
    }

    /// Only media the person resumes from outside the page keeps it: a muted autoplay or ad video, or
    /// sound with no element, still freezes; a muted player whose page handles media keys does not.
    @Test func aMutedAutoplayVideoStillFreezes() {
        #expect(!PageProbe.resumable(BrowserMediaState(title: "hero", isPlaying: true, isMuted: true, isVideo: true)))
        #expect(!PageProbe.resumable(BrowserMediaState(title: "sound", isPlaying: false, isSoundOnly: true)))
        #expect(!PageProbe.resumable(nil))
        #expect(PageProbe.resumable(Self.paused))
        #expect(PageProbe.resumable(BrowserMediaState(title: "player", isPlaying: false, isMuted: true, actions: [.nexttrack])))
    }

    @Test func aPageThatDoesNotAnswerKeepsItsReportedSession() {
        #expect(PageProbe.unanswered(media: Self.paused, muted: false).stopsWhenFrozen)
        #expect(!PageProbe.unanswered(media: nil, muted: false).stopsWhenFrozen)
    }

    /// Live (`BrowserHibernation` with real WebKit pages): the hidden page with a paused session is probed
    /// and stays awake while a plain hidden page beside it freezes; once its session ends it freezes too.
    @Test func aHiddenWebKitPageWithAPausedSessionStaysAwakeUntilTheSessionEnds() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        let player = try await hiddenPage("player", in: rig) { $0.apply(.mediaChanged(Self.paused)) }
        let plain = try await hiddenPage("plain", in: rig)
        try await rig.until("the plain page freezes and the player's probe ends") {
            rig.hibernation.frozen.contains(plain) && !rig.hibernation.freezeProbing.contains(player)
        }
        #expect(!rig.hibernation.frozen.contains(player), "the paused player froze")
        #expect(rig.recorders[player]?.calls.contains(true) == false)

        let tab = try #require(rig.services.cache.browsers[player]?.tab as? WebKitTab)
        tab.apply(.mediaChanged(nil))
        try await rig.until("the player freezes once its session ends") { rig.hibernation.frozen.contains(player) }
    }

    /// A command from outside the page (Pause from the media card, a load, a zoom) wakes a frozen page to run
    /// (`WebKitTab.resumeIfSuspended`). The planner hears it and freezes the page again after `freezeSeconds`;
    /// before, it still counted the page frozen and, with no other deadline pending, left it awake for good.
    @Test func aPageACommandWokeFreezesAgain() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        let reporting = ReportingFreezer()
        rig.hibernation.freezer = { [weak rig] tab -> (any BrowserFreezing)? in
            tab.id.rawValue == reporting.key ? reporting : rig?.recorders[tab.id.rawValue]
        }
        reporting.key = try await hiddenPage("plain", in: rig)
        try await rig.until("the page freezes") { rig.hibernation.frozen.contains(reporting.key) }
        #expect(reporting.calls == [true])

        reporting.wake()
        #expect(!rig.hibernation.frozen.contains(reporting.key), "the planner still counts the woken page frozen")
        try await rig.until("the woken page freezes again") { reporting.calls == [true, true] }
        #expect(rig.hibernation.frozen.contains(reporting.key))
    }

    /// A freezer that reports its page's wakes, as `WebKitTab` does.
    @MainActor final class ReportingFreezer: @MainActor BrowserFreezeReporting {
        var key = ""
        var calls: [Bool] = []
        private(set) var isFrozen = false
        var onFrozenPageChange: (@MainActor (BrowserFrozenPageChange) -> Void)?
        func setFrozen(_ frozen: Bool) -> Bool { calls.append(frozen); isFrozen = frozen; return true }
        /// A command ran in the page.
        func wake() { isFrozen = false; onFrozenPageChange?(.woke) }
    }

    /// A loaded WebKit page, `prepare`d, installed as a tab, shown once, then hidden.
    private func hiddenPage(_ name: String, in rig: NeighborTabsWakeTests.Rig,
                            prepare: (WebKitTab) -> Void = { _ in }) async throws -> String {
        let url = rig.folder.appendingPathComponent("\(name).html")
        try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
        let page = rig.services.cache.webKit.makeWebKitTab()
        page.load(url)
        try await rig.until("\(name) loads") {
            (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
        }
        prepare(page)
        let key = page.id.rawValue
        rig.recorders[key] = NeighborTabsWakeTests.Recorder()
        rig.keys.append(key)
        rig.services.cache.install(page, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        rig.services.cache.withdraw(key, by: rig.pane)
        try #require(rig.services.cache.phase(of: key) == .mountedHidden)
        return key
    }
}
