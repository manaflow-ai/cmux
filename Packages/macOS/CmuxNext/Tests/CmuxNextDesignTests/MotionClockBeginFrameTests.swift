@testable import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
import Testing

/// A ``MotionClock`` hands its animators the frame's ``FrameTick`` (BeginFrame args):
/// the clamped elapsed to step by, the time the frame is shown (`targetTimestamp`, where a presented
/// value is sampled) and the frame's sequence.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MotionClockBeginFrameTests {
    /// Reads the whole frame: what a sampler of presented values implements.
    @MainActor final class FrameReader: MotionAnimating {
        var frames: [FrameTick] = []
        let restAfter: Int
        init(restAfter: Int) { self.restAfter = restAfter }
        func motionStep(_ tick: FrameTick) -> Bool {
            frames.append(tick)
            return frames.count < restAfter
        }
    }

    /// Steps by the elapsed only (the layout driver, the tab strip, the card slot).
    @MainActor final class DtStepper: MotionAnimating {
        var steps: [Double] = []
        func motionStep(_ tick: FrameTick) -> Bool {
            steps.append(tick.elapsed)
            return steps.count < 2
        }
    }

    static func scheduler() -> FrameScheduler {
        FrameScheduler.testing(mediaTime: { 100 }) { _ in MotionClockFakeLink() }
    }

    @Test func anAnimatorSeesEachFramesTargetTimestampAndSequence() throws {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let reader = FrameReader(restAfter: 3)
        clock.run(reader, trace: "test.reader")
        scheduler.frameDidFire(timestamp: 1.000, refreshInterval: 1.0 / 120, targetTimestamp: 1.010)
        scheduler.frameDidFire(timestamp: 1.010, refreshInterval: 1.0 / 120, targetTimestamp: 1.020)
        scheduler.frameDidFire(timestamp: 1.020, refreshInterval: 1.0 / 120, targetTimestamp: 1.030)
        try #require(reader.frames.count == 3)
        #expect(reader.frames.map(\.targetTimestamp) == [1.010, 1.020, 1.030])
        let sequences = reader.frames.map(\.sequence)
        #expect(sequences == [sequences[0], sequences[0] + 1, sequences[0] + 2], "sequences \(sequences)")
        // The dt is the tick's clamped elapsed: the first frame's default 1/60, then the 10 ms between frames.
        let dts = reader.frames.map(\.elapsed)
        #expect(abs(dts[0] - 1.0 / 60) < 1e-9)
        #expect(abs(dts[1] - 0.010) < 1e-9 && abs(dts[2] - 0.010) < 1e-9, "dts \(dts)")
        #expect(!clock.isRunning(reader), "the reader rested on its third frame")
        #expect(!scheduler.hasLink, "the clock went idle with its last animator")
    }

    @Test func aDtOnlyAnimatorStillStepsByTheClampedElapsed() throws {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let stepper = DtStepper()
        clock.run(stepper, trace: "test.stepper")
        scheduler.frameDidFire(timestamp: 2.0, refreshInterval: 1.0 / 60)
        // 100 ms later: the elapsed clamps to 1/30.
        scheduler.frameDidFire(timestamp: 2.1, refreshInterval: 1.0 / 60)
        try #require(stepper.steps.count == 2)
        #expect(abs(stepper.steps[0] - 1.0 / 60) < 1e-9)
        #expect(abs(stepper.steps[1] - 1.0 / 30) < 1e-9, "steps \(stepper.steps)")
        #expect(!clock.isRunning(stepper))
    }

    /// Two animators on one clock see the same frame: one dt, one target, one sequence (DESIGN P4).
    @Test func everyAnimatorOfAFrameSeesTheSameArgs() {
        let scheduler = Self.scheduler()
        let clock = MotionClock(scheduler: { scheduler })
        let first = FrameReader(restAfter: 2), second = FrameReader(restAfter: 2)
        clock.run(first, trace: "test.first")
        clock.run(second, trace: "test.second")
        scheduler.frameDidFire(timestamp: 3.0, refreshInterval: 1.0 / 120, targetTimestamp: 3.008)
        scheduler.frameDidFire(timestamp: 3.008, refreshInterval: 1.0 / 120, targetTimestamp: 3.016)
        #expect(first.frames.map(\.elapsed) == second.frames.map(\.elapsed))
        #expect(first.frames.map(\.targetTimestamp) == second.frames.map(\.targetTimestamp))
        #expect(first.frames.map(\.sequence) == second.frames.map(\.sequence))
        #expect(first.frames.count == 2)
    }
}

@MainActor
private final class MotionClockFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
