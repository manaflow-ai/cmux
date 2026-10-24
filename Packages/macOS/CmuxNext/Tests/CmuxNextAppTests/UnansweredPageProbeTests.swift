import AppKit
@testable import CmuxNextApp
import CmuxNextHibernation
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import Foundation
import Testing

/// A hidden page that does not answer the hibernation probe (a script error, or no reply within
/// its 2 s deadline) used to count as playing media, so a page too busy to answer never froze and
/// was asked again every 30 s for as long as it stayed hidden. The 2026-10-21 audit of Leo's
/// running app found its hottest Chromium renderer at 25 % CPU and a 586 MB footprint. A page
/// that does not answer now counts as unknown; the media the tab already reported still keeps it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct UnansweredPageProbeTests {
    private func tab() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
    }

    @Test func aPageThatDoesNotAnswerIsNotPlayingMedia() async {
        let page = tab()
        page.evaluationResult = .null
        let probe = await BrowserHibernation.probe(page)
        #expect(!probe.playingMedia)
        #expect(probe.exemption != .audio)
        #expect(!probe.answered)
    }

    /// The tab's own media report (the page script's push, no round trip) still keeps it awake.
    @Test func aPageThatDoesNotAnswerButReportedAudibleMediaStaysAwake() async {
        let page = tab()
        page.evaluationResult = .null
        page.simulate(.mediaChanged(BrowserMediaState(title: "song", isPlaying: true)))
        let probe = await BrowserHibernation.probe(page)
        #expect(probe.playingMedia)
        #expect(probe.exemption == .audio)
    }

    /// A real hidden WebKit page whose script keeps its main thread busy: every probe misses its
    /// deadline. It used to stay awake for as long as it was hidden; now it freezes.
    @Test func aHiddenPageTooBusyToAnswerFreezes() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        let key = try await busyHiddenPage(rig)
        try await rig.until("the busy page freezes") { rig.hibernation.frozen.contains(key) }
    }

    /// A loaded page that spins its main thread from 50 ms on, installed as a tab, shown, then hidden.
    private func busyHiddenPage(_ rig: NeighborTabsWakeTests.Rig) async throws -> String {
        let url = rig.folder.appendingPathComponent("busy.html")
        try "<!doctype html><title>busy</title><p>busy</p>".write(to: url, atomically: true, encoding: .utf8)
        let page = rig.services.cache.webKit.makeWebKitTab()
        page.load(url)
        try await rig.until("busy loads") {
            (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string("busy")
        }
        _ = try await page.evaluate("setTimeout(() => { const end = Date.now() + 15000; while (Date.now() < end) {} }, 50); true", world: .page, gesture: .agent)
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
