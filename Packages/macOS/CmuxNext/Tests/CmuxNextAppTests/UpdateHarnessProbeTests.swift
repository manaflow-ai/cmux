#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The update harness probe's card observation (plans/cmux-next/chrome-parity/p06-scheduler.md, FG307, rule 9): a
/// `visible` service observation. The person's Install click applies in that click's input-response pass, before the
/// commit; the updater's own move to Installing flushes on the next frame, not held behind the person's response.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct UpdateHarnessProbeTests {
    @MainActor @Observable final class Card {
        var installing = false
    }

    @Test func aPersonsInstallClickAppliesInTheInputResponseBeforeTheCommit() {
        let (rig, card) = (ProbeRig(), Card())
        defer { rig.stop() }
        var applied: [Bool] = []
        var classes: [MainWorkClass?] = []
        let board = rig.work.budget.board
        let watch = UpdateHarnessProbe.followInstalling(on: rig.work) { card.installing } apply: {
            applied.append($0)
            classes.append(board.running?.workClass)
        }
        rig.work.noteDiscreteInput(expectsFrame: true)
        rig.work.causes.withCause(.person) { card.installing = true }
        #expect(applied == [false], "the click's change applied inside its own handler")
        #expect(rig.work.causes.flushPersonCaused() == 1, "the click's change was not queued for the input-response pass")
        #expect(applied == [false, true], "the click's change did not apply before the commit")
        #expect(classes == [nil, .frame], "the click's change applied outside the input-response pass")
        rig.frame()
        #expect(applied == [false, true], "the frame applied the click's change a second time")
        watch.cancel()
    }

    @Test func theUpdatersOwnMoveToInstallingIsNotHeldByAnInputResponse() {
        let (rig, card) = (ProbeRig(), Card())
        defer { rig.stop() }
        var applied: [Bool] = []
        var classes: [MainWorkClass?] = []
        let board = rig.work.budget.board
        let watch = UpdateHarnessProbe.followInstalling(on: rig.work) { card.installing } apply: {
            applied.append($0)
            classes.append(board.running?.workClass)
        }
        rig.work.noteDiscreteInput(expectsFrame: true)
        card.installing = true
        #expect(rig.work.causes.flushPersonCaused() == 0, "a program change went through the person's pass")
        rig.frame()
        #expect(rig.work.budget.isInputResponseOpen)
        #expect(applied == [false, true], "the updater's change waited behind the person's response")
        #expect(classes == [nil, .visible])
        watch.cancel()
    }
}

/// A scheduler on a fake link kept up by a frame client, so posts wait for hand-fired frames, with a clock the test
/// moves.
@MainActor
private final class ProbeRig {
    let work: MainWorkScheduler
    private let clock: ProbeClock
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let clock = ProbeClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: ProbeNoInput(), uptimeNanos: clock.read)) { _ in
            ProbeFakeLink()
        }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ProbeClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// No pending input: only the open input response holds work.
@MainActor
private final class ProbeNoInput: InputPendingSource {
    func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}

@MainActor
private final class ProbeFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
#endif
