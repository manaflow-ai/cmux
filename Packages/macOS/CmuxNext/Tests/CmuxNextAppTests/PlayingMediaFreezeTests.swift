import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
@testable import CmuxNextBrowser
import Foundation
import Testing

/// 2026-11-25 (`scripts/cmux-next/hidden-video-thaw-live.py`): a muted live video (a canvas `captureStream()`, a
/// camera preview, a dashboard's stream) in a hidden Chromium tab stayed paused for good after the tab showed. The
/// hidden page froze after `browser.freezeHiddenTabs` (30 s): the freeze probe kept only sound, a media session,
/// capture, Web Audio, WebRTC and devices, so a muted video that played did not keep it. Blink pauses each playing
/// media element when its frame freezes and, since M140, never plays it again. A hidden page whose media plays,
/// muted included, now stays awake, as Chrome freezes no such tab; it freezes once its media stops.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PlayingMediaFreezeTests {
    private static let mutedVideo = BrowserMediaState(title: "Live", isPlaying: true, isMuted: true, isVideo: true)
    private static let mutedVideoPaused = BrowserMediaState(title: "Live", isPlaying: false, isMuted: true, isVideo: true)

    /// Live (`BrowserHibernation` with real WebKit pages; the probe is the same for both engines): the hidden page
    /// whose muted video plays is probed and stays awake while a plain hidden page beside it freezes; once the video
    /// pauses, the page freezes too.
    @Test func aHiddenPageWhoseMutedVideoPlaysStaysAwakeUntilItStops() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        let player = try await hiddenPage("player", in: rig) { $0.apply(.mediaChanged(Self.mutedVideo)) }
        let plain = try await hiddenPage("plain", in: rig)
        try await rig.until("the plain page freezes and the player's probe ends") {
            rig.hibernation.frozen.contains(plain) && !rig.hibernation.freezeProbing.contains(player)
        }
        #expect(!rig.hibernation.frozen.contains(player), "the page whose muted video plays froze: Blink pauses its video for good")
        #expect(rig.recorders[player]?.calls.contains(true) == false)

        let tab = try #require(rig.services.cache.browsers[player]?.tab as? WebKitTab)
        tab.apply(.mediaChanged(Self.mutedVideoPaused))
        try await rig.until("the player freezes once its video stops") { rig.hibernation.frozen.contains(player) }
    }

    /// The probe: the tab's report of media that plays, muted or not, or the page's own answer (`plays`, a playing
    /// element in the top document) keeps it from a freeze; paused media, or none, does not. It is no keep reason
    /// against a discard (Chrome's Memory Saver discards a muted tab).
    @Test func playingMediaMutedOrNotStopsAFreezeOnly() async {
        #expect(PageProbe.plays(Self.mutedVideo))
        #expect(!PageProbe.plays(Self.mutedVideoPaused))
        #expect(!PageProbe.plays(nil))
        #expect(PageProbe(mediaPlays: true).stopsWhenFrozen)
        #expect(PageProbe(mediaPlays: true).exemption == nil)
        #expect(PageProbe.unanswered(media: Self.mutedVideo, muted: false).stopsWhenFrozen, "an unanswered page loses its reported video")

        let reported = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        reported.evaluationResult = .string(#"{"media":false,"plays":false,"form":false}"#)
        reported.simulate(.mediaChanged(Self.mutedVideo))
        #expect(await BrowserHibernation.probe(reported).stopsWhenFrozen, "the tab's report of a muted video did not keep it")

        let answered = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        answered.evaluationResult = .string(#"{"media":false,"plays":true,"form":false}"#)
        #expect(await BrowserHibernation.probe(answered).stopsWhenFrozen, "the page's own playing element did not keep it")

        let idle = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        idle.evaluationResult = .string(#"{"media":false,"form":false}"#)
        idle.simulate(.mediaChanged(Self.mutedVideoPaused))
        #expect(await BrowserHibernation.probe(idle).stopsWhenFrozen == false, "a paused muted video kept the page")
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
