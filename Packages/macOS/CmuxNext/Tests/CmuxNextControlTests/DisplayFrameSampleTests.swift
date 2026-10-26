import CmuxNextSignposts
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// The vsync grid that late commits and estimated presents are placed on (``DisplayFrameSample``, p03-rendering
/// 004): the newest link tick a scheduler delivered, kept when its link stops, never a stalled frame, and read
/// without making a link.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DisplayFrameSampleTests {
    private static let hz120 = 1.0 / 120

    @Test func vsyncAfterIsTheEndOfTheFrameATimeFallsIn() throws {
        let sample = try #require(DisplayFrameSample(timestamp: 10, interval: Self.hz120, linkRunning: true))
        #expect(abs(sample.vsync(after: 10.001) - (10 + Self.hz120)) < 1e-9)
        #expect(abs(sample.vsync(after: 10 + Self.hz120 + 0.0001) - (10 + 2 * Self.hz120)) < 1e-9)
        // A time before the sample is on the same grid.
        #expect(abs(sample.vsync(after: 9.999) - 10) < 1e-9)
        // Strictly after: a time on a vsync belongs to the frame that starts there.
        #expect(abs(sample.vsync(after: 10) - (10 + Self.hz120)) < 1e-9)
    }

    /// The first tick after the commit starts the frame that takes it; that frame is shown one period later.
    @Test func thePresentEstimateIsTheFirstTickAfterTheCommitsTarget() throws {
        let sample = try #require(DisplayFrameSample(timestamp: 10, interval: Self.hz120, linkRunning: true))
        #expect(abs(sample.presentEstimate(afterCommit: 10.002) - (10 + 2 * Self.hz120)) < 1e-9)
        let placed = DisplayFrameSample.presentEstimate(afterCommit: 10.002, from: sample)
        #expect(placed.phase == .running)
        #expect(abs(placed.time - (10 + 2 * Self.hz120)) < 1e-9)
    }

    @Test func aStoppedLinkKeepsItsGridForASecondThenTheEstimateIsAGuess() throws {
        let stopped = try #require(DisplayFrameSample(timestamp: 10, interval: Self.hz120, linkRunning: false))
        #expect(stopped.phase(at: 10.5) == .recent)
        #expect(DisplayFrameSample.presentEstimate(afterCommit: 10.5, from: stopped).phase == .recent)
        #expect(stopped.phase(at: 12) == .unknown)
        let guess = DisplayFrameSample.presentEstimate(afterCommit: 12, from: stopped)
        #expect(guess.phase == .unknown)
        #expect(abs(guess.time - (12 + 1.5 * Self.hz120)) < 1e-9, "the sample's period still holds")
        let none = DisplayFrameSample.presentEstimate(afterCommit: 12, from: nil)
        #expect(none.phase == .unknown)
        #expect(abs(none.time - (12 + 1.5 * FrameTick.defaultRefreshInterval)) < 1e-9)
    }

    /// An unpaused link that stopped ticking (the displays sleep, the screen went away) is not a running grid: past
    /// a few periods its tick is recent, past a second unknown.
    @Test func anUnpausedLinkWithAnOldTickIsNotRunning() throws {
        let stalling = try #require(DisplayFrameSample(timestamp: 10, interval: Self.hz120, linkRunning: true))
        #expect(stalling.phase(at: 10 + 2 * Self.hz120) == .running)
        #expect(stalling.phase(at: 10 + DisplayFrameSample.maxRunningPeriods * Self.hz120 + 0.001) == .recent)
        #expect(stalling.phase(at: 10.5) == .recent)
        #expect(stalling.phase(at: 30) == .unknown)
        #expect(DisplayFrameSample.presentEstimate(afterCommit: 30, from: stalling).phase == .unknown)
    }

    @Test func aBadPeriodIsNoSample() {
        #expect(DisplayFrameSample(timestamp: 3, interval: 0, linkRunning: true) == nil)
        #expect(DisplayFrameSample(timestamp: 3, interval: .infinity, linkRunning: true) == nil)
    }

    /// The display clock keeps its last link frame (not a stalled one) after the link stops, says the link
    /// stopped, and reading it makes no link.
    @Test func theDisplayClockKeepsItsLastLinkFrameAcrossAStallAndAStop() throws {
        var made = 0
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in
            made += 1
            return SampleFakeLink()
        }
        let displays = scheduler.displayClock
        #expect(displays.newestFrame() == nil)
        let client = FrameClient(owner: "spring", on: scheduler) { _ in true }
        client.activate()
        scheduler.frameDidFire(timestamp: 20, refreshInterval: Self.hz120, targetTimestamp: 20 + Self.hz120)
        scheduler.frameDidFire(timestamp: nil)  // a stalled frame: its time is not a vsync
        let running = try #require(displays.newestFrame())
        #expect(running.timestamp == 20 && running.linkRunning)
        #expect(abs(running.interval - Self.hz120) < 1e-12)
        client.deactivate()
        let stopped = try #require(displays.newestFrame())
        #expect(stopped.timestamp == 20 && !stopped.linkRunning)
        #expect(made == 1)
        _ = displays.newestFrame()
        #expect(made == 1 && !scheduler.hasLink && displays.liveLinks == 0, "reading the frame makes no link")
    }

    @Test func thePhaseHasAFixedRingCode() {
        #expect(VsyncPhase.allCases.map(\.traceCode) == [1, 2, 3])
        #expect(VsyncPhase.allCases.map(\.rawValue) == ["running", "recent", "unknown"])
    }
}

private final class SampleFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
