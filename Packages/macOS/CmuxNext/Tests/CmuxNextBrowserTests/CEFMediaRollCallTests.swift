@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Testing

/// The media roll call's deadline (S5 review, cmux-ad): it runs on an injected clock, a new
/// document or the browser's end cancels it, and a frame that answers after it is not lost.
@MainActor
@Suite struct CEFMediaRollCallTests {
    @Test func theDeadlineRunsOnTheInjectedClock() async throws {
        let clock = ManualClock()
        let rollCall = CEFMediaRollCall(limit: .seconds(2), clock: clock)
        var ended = 0
        rollCall.start { ended += 1 }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(ended == 0 && rollCall.isPending)
        clock.advance(by: .seconds(1))
        for _ in 0..<20 where ended == 0 { await Task.yield() }
        #expect(ended == 1)
        #expect(!rollCall.isPending)
    }

    @Test func aCancelEndsItWithNothingDropped() async throws {
        let clock = ManualClock()
        let rollCall = CEFMediaRollCall(limit: .seconds(2), clock: clock)
        var ended = 0
        rollCall.start { ended += 1 }
        try await clock.waitForSleeper()
        rollCall.cancel()  // a new document's commit, or the browser's end
        #expect(!rollCall.isPending)
        clock.advance(by: .seconds(5))
        for _ in 0..<20 { await Task.yield() }
        #expect(ended == 0)
    }

    /// A busy frame (an ad under load) that answers after the deadline is dropped, then its late
    /// report adds it again: a real player is never lost for good.
    @Test func aFrameThatAnswersLateIsAddedAgainByItsReport() {
        var machine = BrowserTabStateMachine()
        let player = BrowserMediaState(title: "Player", isPlaying: true, isVideo: true, position: 4, duration: 60)
        machine.apply(.mediaChanged(player, frame: "busy"))
        machine.apply(.mediaRollCallStarted)
        machine.apply(.mediaRollCallEnded)
        #expect(machine.state.media == nil, "the silent frame is dropped at the deadline")
        machine.apply(.mediaChanged(player, frame: "busy"))
        #expect(machine.state.media?.title == "Player", "its late answer did not bring it back")
    }
}
