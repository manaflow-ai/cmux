import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// Each ``FrameTick`` carries BeginFrame args (Chrome's `viz::BeginFrameArgs`,
/// components/viz/common/frame_sinks/begin_frame_args.h): the frame's time, the time it is shown
/// (`targetTimestamp`, the deadline), the refresh interval and a sequence number.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerBeginFrameTests {
    @Test func aLinkFrameCarriesItsTargetTimestampAndASequence() {
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in BeginFrameFakeLink() }
        var ticks: [FrameTick] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in ticks.append(tick); return true }
        client.activate()
        scheduler.frameDidFire(timestamp: 10, refreshInterval: 1.0 / 120, targetTimestamp: 10.008)
        scheduler.frameDidFire(timestamp: 10.008, refreshInterval: 1.0 / 120, targetTimestamp: 10.016)
        client.deactivate()
        #expect(ticks.map(\.targetTimestamp) == [10.008, 10.016])
        #expect(ticks.map(\.timestamp) == [10, 10.008])
        let sequences = ticks.map(\.sequence)
        #expect(sequences.count == 2 && sequences[1] == sequences[0] + 1, "sequences \(sequences)")
    }

    /// A caller that gives no target (tests, the stall path) gets the frame time plus one refresh.
    @Test func aFrameWithoutATargetIsShownOneRefreshLater() throws {
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in BeginFrameFakeLink() }
        var ticks: [FrameTick] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in ticks.append(tick); return true }
        client.activate()
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 0.01)
        client.deactivate()
        let tick = try #require(ticks.first)
        #expect(abs(tick.targetTimestamp - 2.01) < 1e-12)
    }

    /// A frame with no link time reads the scheduler's injected media time, not `CACurrentMediaTime()`,
    /// and is shown one interval later: the link's last one, 1/60 before any link frame.
    @Test func aSynthesizedFrameUsesTheInjectedMediaTime() throws {
        let scheduler = FrameScheduler.testing(mediaTime: { 777 }) { _ in BeginFrameFakeLink() }
        var ticks: [FrameTick] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in ticks.append(tick); return true }
        client.activate()
        scheduler.frameDidFire(timestamp: nil)
        scheduler.frameDidFire(timestamp: 776.5, refreshInterval: 1.0 / 120)
        scheduler.frameDidFire(timestamp: nil)
        client.deactivate()
        try #require(ticks.count == 3)
        #expect(ticks[0].timestamp == 777)
        #expect(abs(ticks[0].targetTimestamp - (777 + 1.0 / 60)) < 1e-9)
        #expect(ticks[0].refreshInterval == nil)
        #expect(abs(ticks[2].targetTimestamp - (777 + 1.0 / 120)) < 1e-9, "the link's last interval")
        #expect(ticks[2].refreshInterval == nil)
    }

    /// The sequence counts the scheduler's frames: a client that went idle and came back sees the gap.
    @Test func aClientThatMissedFramesSeesTheGapInTheSequence() {
        let scheduler = FrameScheduler.testing(mediaTime: { 500 }) { _ in BeginFrameFakeLink() }
        let keeper = FrameClient(owner: "keeper", on: scheduler) { _ in true }
        keeper.activate()
        var seen: [UInt64] = []
        let probe = FrameClient(owner: "probe", on: scheduler) { tick in seen.append(tick.sequence); return true }
        probe.activate()
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        probe.deactivate()
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        scheduler.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        probe.activate()
        scheduler.frameDidFire(timestamp: 4, refreshInterval: 1.0 / 60)
        probe.deactivate()
        keeper.deactivate()
        #expect(seen.count == 2 && seen[1] == seen[0] + 3, "sequences \(seen)")
    }

    /// The tick's public initializer: readers are tested with a fake tick.
    @Test func aFakeTickDefaultsItsTarget() {
        let shown = FrameTick(timestamp: 1, elapsed: 0.01, rawElapsed: 0.01, refreshInterval: 0.01)
        #expect(abs(shown.targetTimestamp - 1.01) < 1e-12)
        #expect(shown.sequence == 0)
        let stalled = FrameTick(timestamp: 3, elapsed: 0.01, rawElapsed: 0.2, refreshInterval: nil)
        #expect(abs(stalled.targetTimestamp - (3 + FrameTick.defaultRefreshInterval)) < 1e-12)
        let given = FrameTick(timestamp: 1, elapsed: 0.01, rawElapsed: 0.01, refreshInterval: 0.01,
                              targetTimestamp: 1.5, sequence: 9)
        #expect(given.targetTimestamp == 1.5)
        #expect(given.sequence == 9)
    }
}

@MainActor
private final class BeginFrameFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
