@testable import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// `motion.late_commits` (``MotionLateCommits``, p03-rendering 004): a main Core Animation commit during a Motion
/// animation that ends past a deadline its turn could have met counts once (a tick's turn: the tick's target; any
/// other turn: a whole frame passed during it); a short turn that only crosses a vsync is not late; nothing is
/// recorded with no animation; every gate animation counts as motion (``MotionActivity``), not only the ones that
/// settle at sleep; and the counter reads the key display's last tick without starting a display link or a
/// ``FrameClient``.
@MainActor
@Suite(.serialized) struct MotionLateCommitsTests {
    @MainActor final class Clock {
        var time: CFTimeInterval = 100
        /// The grid's newest tick: a test moves it to deliver a tick in the middle of a turn.
        var frame: DisplayFrameSample? = MotionLateCommitsTests.grid
    }

    private static let hz120 = 1.0 / 120
    /// A 120 Hz grid with a vsync at 100 s: frames end at 100.00833, 100.01667, ...
    private static let grid = DisplayFrameSample(timestamp: 100, interval: hz120, linkRunning: true)

    private func makeCounter(clock: Clock, animating: @escaping @MainActor () -> Bool = { true })
        -> (MotionLateCommits, () -> [(Double, Double)]) {
        var recorded: [(Double, Double)] = []
        let counter = MotionLateCommits(newestFrame: { clock.frame }, isAnimating: animating, now: { clock.time }) {
            recorded.append(($0, $1))
        }
        return (counter, { recorded })
    }

    /// A tick that ran in the turn sets the deadline: its target timestamp (one period after the tick's vsync).
    @Test func aTickTurnPastItsTargetCountsOneLateCommit() throws {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100.0085
        counter.turnDidWake()
        clock.frame = DisplayFrameSample(timestamp: 100 + Self.hz120, interval: Self.hz120, linkRunning: true)
        clock.time = 100.0175  // past the tick's target, 100.01667
        counter.commitDidEnd()
        #expect(counter.lateCount == 1)
        #expect(counter.judgedCount == 1)
        let late = try #require(recorded().first)
        #expect(abs(late.0 - (100.0175 - (100 + 2 * Self.hz120)) * 1_000) < 1e-6, "ms past the tick's target")
        #expect(abs(late.1 - 9) < 1e-6, "the turn's start to the commit's end")
    }

    @Test func aTickTurnInsideItsTargetIsNotLate() {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100.0085
        counter.turnDidWake()
        clock.frame = DisplayFrameSample(timestamp: 100 + Self.hz120, interval: Self.hz120, linkRunning: true)
        clock.time = 100.015
        counter.commitDidEnd()
        #expect(counter.lateCount == 0 && counter.judgedCount == 1)
        #expect(recorded().isEmpty)
    }

    /// A 0.3 ms event turn that wakes 0.1 ms before a vsync crosses it, but could never have made that frame: not
    /// late (the old "ends after the next vsync" rule counted it, and any turn of length d with probability
    /// d / period).
    @Test func aShortTurnThatCrossesAVsyncIsNotLate() {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100 + Self.hz120 - 0.0001
        counter.turnDidWake()
        clock.time += 0.0003
        counter.commitDidEnd()
        #expect(counter.lateCount == 0)
        #expect(counter.judgedCount == 1)
        #expect(recorded().isEmpty)
    }

    /// An event turn during which a whole frame passed missed that frame: late, measured past the vsync after it.
    @Test func anEventTurnSpanningAWholeFrameIsLate() throws {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100.002
        counter.turnDidWake()
        clock.time = 100.0175  // past 100.00833 + one period
        counter.commitDidEnd()
        #expect(counter.lateCount == 1)
        let late = try #require(recorded().first)
        #expect(abs(late.0 - (100.0175 - (100 + 2 * Self.hz120)) * 1_000) < 1e-6)
    }

    /// A turn that did not sleep starts where the previous commit ended, with that commit's tick.
    @Test func aTurnWithoutAWakeStartsAtThePreviousCommit() {
        let clock = Clock()
        let (counter, _) = makeCounter(clock: clock)
        clock.time = 100.001
        counter.turnDidWake()
        clock.time = 100.0175  // late: a whole frame passed
        counter.commitDidEnd()
        clock.time = 100.025  // starts at 100.0175: its deadline is one period past the vsync at 100.025
        counter.commitDidEnd()
        #expect(counter.lateCount == 1)
        #expect(counter.judgedCount == 2)
    }

    @Test func nothingIsRecordedWithoutAnAnimation() {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock, animating: { false })
        counter.turnDidWake()
        clock.time = 100.5
        counter.commitDidEnd()
        #expect(counter.lateCount == 0 && counter.judgedCount == 0 && counter.unjudgedCount == 0)
        #expect(recorded().isEmpty)
    }

    /// The turn an animation starts in began before the motion: it is not judged, and the next one is.
    @Test func theTurnAnAnimationStartsInIsNotJudged() {
        let clock = Clock()
        var animating = false
        let (counter, recorded) = makeCounter(clock: clock, animating: { animating })
        clock.time = 100.001
        counter.turnDidWake()
        animating = true
        clock.time = 100.0175
        counter.commitDidEnd()
        #expect(counter.unjudgedCount == 1 && counter.judgedCount == 0)
        clock.time = 100.018
        counter.commitDidEnd()
        #expect(counter.judgedCount == 1 && counter.lateCount == 0)
        #expect(recorded().isEmpty)
    }

    /// No tick, one too old to hold the grid, or an unpaused link whose tick is that old (a stall): the commit is
    /// not judged, never counted late.
    @Test(arguments: [nil, DisplayFrameSample(timestamp: 10, interval: 1.0 / 120, linkRunning: false),
                      DisplayFrameSample(timestamp: 10, interval: 1.0 / 120, linkRunning: true)])
    func aCommitWithNoRecentTickIsNotJudged(_ frame: DisplayFrameSample?) {
        let clock = Clock()
        clock.frame = frame
        let (counter, recorded) = makeCounter(clock: clock)
        counter.turnDidWake()
        clock.time = 100.05
        counter.commitDidEnd()
        #expect(counter.unjudgedCount == 1)
        #expect(counter.lateCount == 0 && counter.judgedCount == 0)
        #expect(recorded().isEmpty)
    }

    /// A plain gate animation (no settle at sleep) is motion for the counter: the app's in-flight signal comes from
    /// the gate, so its commits are judged.
    @Test func aPlainGateAnimationIsMotion() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        #expect(Motion.panes.animatesMovement)
        Motion.panes.animate(.move) {}
        #expect(MotionActivity.isAnimating)
        let clock = Clock()
        let counter = MotionLateCommits(newestFrame: { clock.frame }, isAnimating: { MotionActivity.isAnimating },
                                        now: { clock.time }) { _, _ in }
        clock.time = 100.001
        counter.turnDidWake()
        clock.time = 100.003
        counter.commitDidEnd()
        #expect(counter.judgedCount == 1)
    }

    /// Layer animations a gate makes count for their length; a loop that repeats forever (a spinner) never ends,
    /// so it is not motion.
    @Test func layerAnimationsCountForTheirLengthAndLoopsNot() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let spring = Motion.tabs.springAnimation(.move, "position", from: 0, to: 1)
        #expect(MotionActivity.activeSeconds(spring) == spring.duration)
        let spin = try #require(Motion.indicators.spinAnimation())
        #expect(MotionActivity.activeSeconds(spin) == .infinity)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.duration = 0.25
        pulse.autoreverses = true
        pulse.repeatCount = 3
        #expect(abs(MotionActivity.activeSeconds(pulse) - 1.5) < 1e-9)
        pulse.repeatDuration = 0.4
        #expect(abs(MotionActivity.activeSeconds(pulse) - 0.4) < 1e-9)
    }

    /// The app's counter watches the main run loop through one observer and reads the display clock's last frame:
    /// no scheduler makes a link and none gains a client.
    @Test func theCounterStartsNoLinkAndNoFrameClient() {
        let schedulers = FrameScheduler.all
        let linksBefore = schedulers.map(\.linksMade)
        let linkedBefore = schedulers.map(\.hasLink)
        let clientsBefore = schedulers.map(\.activeClients)
        let liveBefore = FrameScheduler.appDisplays.liveLinks
        let counter = MotionLateCommits(displays: FrameScheduler.appDisplays)
        defer { counter.stop() }
        #expect(counter.isWatching)
        MotionActivity.began(seconds: 0.4)
        #expect(MotionActivity.isAnimating)
        counter.turnDidWake()
        counter.commitDidEnd()
        #expect(counter.judgedCount + counter.unjudgedCount == 1, "the commit during the move was seen")
        #expect(schedulers.map(\.linksMade) == linksBefore)
        #expect(schedulers.map(\.hasLink) == linkedBefore)
        #expect(schedulers.map(\.activeClients) == clientsBefore)
        #expect(FrameScheduler.appDisplays.liveLinks == liveBefore)
        #expect(FrameScheduler.all.count == schedulers.count, "no scheduler was made")
        counter.stop()
        #expect(!counter.isWatching)
    }
}
