import CmuxNextBrowser
import Foundation
import Testing

/// A browser tab's playback position, from its page's media reports (cx-ouoxo): the Now Playing
/// card and macOS Now Playing read it. A heartbeat that only says the track moved on as expected
/// leaves the tab's state alone, but a resume, a pause or a speed change takes the new report's
/// position. Folding those into the old position put a track resumed after a long pause at its end.
@MainActor @Suite struct NowPlayingPositionTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func report(_ seconds: TimeInterval, at offset: TimeInterval, playing: Bool = true, rate: Double = 1) -> BrowserMediaState {
        BrowserMediaState(title: "Weightless", artist: "Marconi Union", isPlaying: playing, position: seconds, duration: 480,
                          rate: rate, positionDate: start.addingTimeInterval(offset))
    }

    func tab(after reports: [BrowserMediaState]) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/listen"), origin: .user))
        for report in reports { tab.simulate(.mediaChanged(report)) }
        return tab
    }

    func position(_ tab: MockBrowserTab, at offset: TimeInterval) -> TimeInterval? {
        tab.state.media?.position(at: Self.start.addingTimeInterval(offset))
    }

    @Test func aTrackResumedAfterALongPauseIsWhereItPaused() throws {
        // Plays at 1:00, pauses there half a second later, resumes ten minutes later at 1:00.
        let tab = tab(after: [Self.report(60, at: 0), Self.report(60, at: 0.5, playing: false), Self.report(60, at: 600)])
        let now = try #require(position(tab, at: 602), "no media state")
        #expect(abs(now - 62) < 0.5, "two seconds after resuming at 1:00 the tab says \(now) s")
        #expect(tab.state.media?.isPlaying == true)
    }

    @Test func aPauseHoldsWhereThePageSaysItStopped() throws {
        // Plays from 0:00; steady heartbeats; pauses at 2:00.
        let tab = tab(after: [Self.report(0, at: 0), Self.report(3, at: 3), Self.report(60, at: 60), Self.report(120, at: 120, playing: false)])
        let now = try #require(position(tab, at: 300), "no media state")
        #expect(abs(now - 120) < 0.5, "paused at 2:00, the tab says \(now) s")
    }

    @Test func aSpeedChangeMovesOnFromTheChange() throws {
        // Normal speed from 0:00; at 1:00 it plays twice as fast.
        let tab = tab(after: [Self.report(0, at: 0), Self.report(60, at: 60, rate: 2)])
        let now = try #require(position(tab, at: 70), "no media state")
        #expect(abs(now - 80) < 0.5, "ten seconds at 2x after 1:00 is 1:20, the tab says \(now) s")
    }

    @Test func aHeartbeatOnCourseLeavesTheTabsStateAlone() {
        let first = Self.report(0, at: 0)
        let tab = tab(after: [first, Self.report(3.2, at: 3), Self.report(6.1, at: 6)])
        #expect(tab.state.media == first, "a steady heartbeat changed the tab's state: \(String(describing: tab.state.media))")
    }
}
