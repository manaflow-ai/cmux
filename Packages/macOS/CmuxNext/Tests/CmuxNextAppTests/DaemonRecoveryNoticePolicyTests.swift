@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Foundation
import Testing

/// Leo, 2026-11-03, on "cmux-tui stopped and could not start again. cmux keeps trying." over a
/// window on a heavily loaded Mac: "why did this show up". The notice showed on the first failed
/// `server ensure` after the local daemon's connection dropped, while the reconnect was still
/// retrying by itself. The rule: a start that failed once or twice, or only for a short while, is
/// retried quietly; cmux-tui counts as down (``DaemonRecovery/startFailurePersists``) only once
/// starts kept failing (``DaemonRecovery/NoticePolicy``), or at once on a full disk, which only the
/// person can fix.
@MainActor @Suite
struct DaemonRecoveryNoticePolicyTests {
    private static let failed = DaemonStartFailure(kind: .failed, detail: "exit 1: the detached session owner did not become ready")
    private static let diskFull = DaemonStartFailure(kind: .diskFull, detail: "No space left on device (os error 28)")

    /// A recovery on a clock the test moves.
    @MainActor private final class Fixture {
        var clock = ContinuousClock.now
        let recovery = DaemonRecovery()
        var failedInARow = 0

        init() {
            recovery.now = { [unowned self] in clock }
        }

        func fail(_ failure: DaemonStartFailure = DaemonRecoveryNoticePolicyTests.failed, after: Duration = .zero) {
            clock += after
            failedInARow += 1
            recovery.noteStart(failure, failedInARow: failedInARow)
        }

        func succeed() {
            failedInARow = 0
            recovery.noteStart(nil, failedInARow: 0)
        }
    }

    @Test func aRestartThatFailsBrieflyIsRetriedQuietly() {
        let fixture = Fixture()
        // The reconnect's first ensures under heavy load: three fail within a minute.
        fixture.fail()
        #expect(!fixture.recovery.startFailurePersists, "one failed start counted as cmux-tui being down")
        fixture.fail(after: .seconds(20))
        fixture.fail(after: .seconds(30))
        #expect(fixture.recovery.startFailure != nil)
        #expect(!fixture.recovery.startFailurePersists, "three failed starts within a minute counted as cmux-tui being down")
        // The daemon is back: nothing showed, and the streak is over.
        fixture.succeed()
        #expect(!fixture.recovery.startFailurePersists)
        #expect(fixture.recovery.startFailure == nil)
    }

    @Test func aStartThatKeepsFailingCountsAsDown() {
        let fixture = Fixture()
        fixture.fail()
        fixture.fail(after: .seconds(30))
        fixture.fail(after: .seconds(30))
        #expect(!fixture.recovery.startFailurePersists)
        fixture.fail(after: .seconds(30))
        #expect(!fixture.recovery.startFailurePersists, "90 s of failed starts is still within the window")
        fixture.fail(after: .seconds(30))
        #expect(fixture.recovery.startFailurePersists, "starts failed for two minutes and cmux-tui is not told as down")
    }

    @Test func aLongStartThatFailedTwiceIsNotYetDown() {
        let fixture = Fixture()
        // Two slow ensures, each at its 150 s cap: long, but only two attempts.
        fixture.fail()
        fixture.fail(after: .seconds(150))
        #expect(!fixture.recovery.startFailurePersists, "two failed starts counted as cmux-tui being down")
        fixture.fail(after: .seconds(30))
        #expect(fixture.recovery.startFailurePersists)
    }

    @Test func aFullDiskCountsAsDownAtOnce() {
        let fixture = Fixture()
        fixture.fail(Self.diskFull)
        #expect(fixture.recovery.startFailurePersists, "a full disk, which only the person can fix, was not told at once")
    }

    @Test func aWorkingStartRestartsTheWindow() {
        let fixture = Fixture()
        fixture.fail()
        fixture.fail(after: .seconds(60))
        fixture.succeed()
        // A new streak: its window starts at its own first failure, not the earlier one's.
        fixture.fail(after: .seconds(60))
        fixture.fail(after: .seconds(10))
        fixture.fail(after: .seconds(10))
        #expect(!fixture.recovery.startFailurePersists, "an earlier, ended streak counted toward this one")
    }

    /// The launcher's outcome reports every failed ensure, also one that fails the same way as the last,
    /// so the recovery counts the streak.
    @Test func everyFailedEnsureCountsInTheOutcome() {
        let outcome = EnsureOutcome()
        let error = DaemonError.launchFailed("exit 1: the detached session owner did not become ready")
        outcome.note(error)
        outcome.note(error)
        outcome.note(error)
        #expect(outcome.failedInARow == 3)
        outcome.note(nil, pid: 42)
        #expect(outcome.failedInARow == 0)
        #expect(outcome.failure == nil)
    }
}
