@testable import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// `motion.late_commits` (``MotionLateCommits``, p03-rendering 004): a main Core Animation commit during a Motion
/// animation that ends after the vsync of the frame its turn began in counts once; nothing is recorded with no
/// animation; and the counter reads the newest tick without starting a display link or a ``FrameClient``.
@MainActor
@Suite(.serialized) struct MotionLateCommitsTests {
    final class Clock {
        var time: CFTimeInterval = 100
    }

    /// A 120 Hz grid with a vsync at 100 s: frames end at 100.00833, 100.01667, ...
    private static let grid = DisplayFrameSample(timestamp: 100, interval: 1.0 / 120, linkRunning: true)

    private func makeCounter(clock: Clock, animating: @escaping @MainActor () -> Bool = { true },
                             frame: DisplayFrameSample? = grid) -> (MotionLateCommits, () -> [(Double, Double)]) {
        var recorded: [(Double, Double)] = []
        let counter = MotionLateCommits(newestFrame: { frame }, isAnimating: animating, now: { clock.time }) {
            recorded.append(($0, $1))
        }
        return (counter, { recorded })
    }

    @Test func aCommitPastItsFramesVsyncCountsOneLateCommit() throws {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100.002
        counter.turnDidWake()
        clock.time = 100.0095
        counter.commitDidEnd()
        #expect(counter.lateCount == 1)
        #expect(counter.judgedCount == 1)
        let late = try #require(recorded().first)
        #expect(abs(late.0 - (100.0095 - (100 + 1.0 / 120)) * 1_000) < 1e-6, "ms past the vsync")
        #expect(abs(late.1 - 7.5) < 1e-6, "the turn's start to the commit's end")
    }

    @Test func aCommitInsideItsFrameIsNotLate() {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock)
        clock.time = 100.001
        counter.turnDidWake()
        clock.time = 100.005
        counter.commitDidEnd()
        #expect(counter.lateCount == 0)
        #expect(counter.judgedCount == 1)
        #expect(recorded().isEmpty)
    }

    /// A turn that did not sleep starts where the previous commit ended: a commit right after a vsync is judged
    /// against the next one, not the old frame's.
    @Test func aTurnWithoutAWakeStartsAtThePreviousCommit() {
        let clock = Clock()
        let (counter, _) = makeCounter(clock: clock)
        clock.time = 100.001
        counter.turnDidWake()
        clock.time = 100.009  // late: past 100.00833
        counter.commitDidEnd()
        clock.time = 100.012  // in the frame that began at 100.00833 (the turn began at 100.009)
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
        clock.time = 100.0095
        counter.commitDidEnd()
        #expect(counter.unjudgedCount == 1 && counter.judgedCount == 0)
        clock.time = 100.0101  // the next turn starts at the last commit, in the frame ending at 100.01667
        counter.commitDidEnd()
        #expect(counter.judgedCount == 1 && counter.lateCount == 0)
        #expect(recorded().isEmpty)
    }

    /// No tick, or one too old to hold the grid: the commit is not judged, never counted late.
    @Test(arguments: [nil, DisplayFrameSample(timestamp: 10, interval: 1.0 / 120, linkRunning: false)])
    func aCommitWithNoRecentTickIsNotJudged(_ frame: DisplayFrameSample?) {
        let clock = Clock()
        let (counter, recorded) = makeCounter(clock: clock, frame: frame)
        counter.turnDidWake()
        clock.time = 100.05
        counter.commitDidEnd()
        #expect(counter.unjudgedCount == 1)
        #expect(counter.lateCount == 0 && counter.judgedCount == 0)
        #expect(recorded().isEmpty)
    }

    /// The app's counter watches the main run loop through one observer and reads the display clock's newest
    /// frame: no scheduler makes a link and none gains a client.
    @Test func theCounterStartsNoLinkAndNoFrameClient() {
        let schedulers = FrameScheduler.all
        let linksBefore = schedulers.map(\.linksMade)
        let linkedBefore = schedulers.map(\.hasLink)
        let clientsBefore = schedulers.map(\.activeClients)
        let liveBefore = FrameScheduler.appDisplays.liveLinks
        let counter = MotionLateCommits(newestFrame: { FrameScheduler.appDisplays.newestFrame() })
        defer { counter.stop() }
        #expect(counter.isWatching)
        let done = MotionInFlight.track(settle: {}, seconds: 0.4, completion: nil)
        #expect(MotionInFlight.isAnimating)
        counter.turnDidWake()
        counter.commitDidEnd()
        #expect(counter.judgedCount + counter.unjudgedCount == 1, "the commit during the move was seen")
        #expect(schedulers.map(\.linksMade) == linksBefore)
        #expect(schedulers.map(\.hasLink) == linkedBefore)
        #expect(schedulers.map(\.activeClients) == clientsBefore)
        #expect(FrameScheduler.appDisplays.liveLinks == liveBefore)
        #expect(FrameScheduler.all.count == schedulers.count, "no scheduler was made")
        done()
        counter.stop()
        #expect(!counter.isWatching)
    }

    /// A move that does not animate (motion off: zero seconds) is not an animation for the counter.
    @Test func aZeroLengthMoveIsNotAnAnimation() {
        let before = MotionInFlight.isAnimating
        let done = MotionInFlight.track(settle: {}, seconds: 0, completion: nil)
        #expect(MotionInFlight.isAnimating == before)
        done()
    }
}
