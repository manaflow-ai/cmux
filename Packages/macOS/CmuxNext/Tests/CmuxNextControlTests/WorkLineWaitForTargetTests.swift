import CmuxNextWakeups
import Observation
import Testing

/// `WorkLine.waitForTarget(after:listed:mayReturn:limit:owner:)`: a work of a line waits for the thing that it acts on,
/// then for its turn, and waits again for a thing that is hidden at its turn and can come back. In the app, a new tab's
/// move waits for its tab, then for the move of the new tab before it, and a close that has not settled can hide the tab
/// in that second wait.
///
/// The rows have no app and no daemon. The thing is a fake that the Observation module tracks, as it tracks the store's
/// tab list: a change of the fake ends a wait. The place before the work's is a task that changes the fake, so the change
/// comes in the wait for the turn (the test and the line are on the main actor: that task runs at the function's first
/// suspension). Each row reads three things: what the function returns, the line's count of works that found their thing
/// hidden at their turn, which is the count of second waits, and how many times the limit's timer fired (the wakeup
/// ledger's count for the row's own owner name).
///
/// The function was new with the first six rows, so they have no red first. The last row has one (the
/// second wait ends when the thing can no longer come back, not at its limit): before that mend its
/// wait ends by its limit, and the row fails by its count of the timer's fires.
///
/// Limits:
/// - No row sleeps, polls or reads a clock. A row whose wait must not end by its limit passes a limit of 10 minutes and
///   asserts that the timer did not fire. A row that needs the end of the limit passes a limit of 0. The last row
///   passes a limit of 20 seconds, so that its red comes inside the suite's time limit; no expect reads that time.
/// - The function asks if the thing can come back at the turn, and again inside the second wait (each time the
///   Observation reads the wait's condition). So a row counts at least one question, not one.
/// - The suite's time limit of 1 minute stops a row whose wait does not end. It is no verdict of a row.
/// - The fake is not the store: the rows do not say that the store's tab list is tracked. The app's row does
///   (`ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests`).
@MainActor @Suite(.timeLimit(.minutes(1)))
struct WorkLineWaitForTargetTests {
    /// The thing that a work acts on: shown or hidden, whether what hid it has settled, and whether it can come back.
    @Observable @MainActor final class Thing {
        var shown: Bool
        var hideSettled = false
        var canReturn = true

        init(shown: Bool) { self.shown = shown }
    }

    /// How many times the function asked a row if the thing can come back.
    @MainActor final class Asked { var count = 0 }

    /// A limit that no row reaches.
    private static let long: Duration = .seconds(600)

    /// How many times the limit's timer of `owner` fired.
    private static func fires(_ owner: String) -> UInt64 {
        WakeupLedger.shared.snapshot().filter { $0.owner == owner }.reduce(0) { $0 + $1.count }
    }

    /// The thing is listed at once: found, with no wait.
    @Test func aThingListedAtOnceIsFoundWithNoWait() async {
        let owner = "WorkLineWaitForTargetTests.listedAtOnce", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let found = await line.waitForTarget(after: nil, listed: { thing.shown }, mayReturn: { asked.count += 1; return true }, limit: Self.long, owner: owner)
        #expect(found, "the thing was listed at once and the function says that it was not found")
        #expect(line.targetsHiddenAtTheirTurn == 0 && asked.count == 0,
                "\(line.targetsHiddenAtTheirTurn) second waits and \(asked.count) questions if the thing can come back (want 0 and 0: the thing was never hidden)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: there was no wait)")
    }

    /// The thing is never listed and the limit is at its end (a limit of 0): not found, and the one wait ended by its limit.
    @Test func aThingNeverListedIsNotFoundWhenTheLimitEnds() async {
        let owner = "WorkLineWaitForTargetTests.neverListed", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: false), asked = Asked()
        let found = await line.waitForTarget(after: nil, listed: { thing.shown }, mayReturn: { asked.count += 1; return true }, limit: .zero, owner: owner)
        #expect(!found, "the thing was never listed and the function says that it was found")
        #expect(line.targetsHiddenAtTheirTurn == 0 && asked.count == 0,
                "\(line.targetsHiddenAtTheirTurn) second waits and \(asked.count) questions if the thing can come back (want 0 and 0: a thing that was never listed is not waited for again)")
        #expect(Self.fires(owner) == before + 1, "the limit's timer fired \(Self.fires(owner) - before) times (want 1: the first wait ended by its limit)")
    }

    /// The thing is listed, the place before the work's hides it, and it comes back after the second wait began: found,
    /// with one second wait, which the thing's return ended (the timer did not fire).
    @Test func aThingHiddenAtItsTurnIsWaitedForAgainAndFoundWhenItComesBack() async {
        let owner = "WorkLineWaitForTargetTests.comesBack", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let earlier = Task { @MainActor in thing.shown = false; return 0 }
        let found = await line.waitForTarget(after: earlier, listed: { thing.shown }, mayReturn: {
            asked.count += 1
            if asked.count == 1 { Task { @MainActor in thing.shown = true } } // runs when the function is in its second wait
            return true
        }, limit: Self.long, owner: owner)
        #expect(found && thing.shown, "found \(found), shown \(thing.shown) (want both: the thing came back)")
        #expect(line.targetsHiddenAtTheirTurn == 1 && asked.count >= 1,
                "\(line.targetsHiddenAtTheirTurn) second waits and \(asked.count) questions if the thing can come back (want 1 wait and at least 1 question: no second wait after the thing came back)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: the thing's return ended the second wait, not the limit)")
    }

    /// The thing is hidden at its turn and it cannot come back: no second wait.
    @Test func aThingHiddenAtItsTurnThatCannotComeBackIsNotWaitedFor() async {
        let owner = "WorkLineWaitForTargetTests.cannotComeBack", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let earlier = Task { @MainActor in thing.shown = false; return 0 }
        let found = await line.waitForTarget(after: earlier, listed: { thing.shown }, mayReturn: { asked.count += 1; return false }, limit: Self.long, owner: owner)
        #expect(found && !thing.shown, "found \(found), shown \(thing.shown) (want found, as the thing was listed inside the limit, and not shown)")
        #expect(line.targetsHiddenAtTheirTurn == 0 && asked.count == 1,
                "\(line.targetsHiddenAtTheirTurn) second waits and \(asked.count) questions if the thing can come back (want 0 and 1: the answer was no)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: there was no wait)")
    }

    /// The thing is hidden at its turn and what hid it has settled (in the app: the tab's close settled, which the
    /// condition of the move counts as listed): no second wait, and no question if it can come back.
    @Test func aThingWhoseHideSettledAtItsTurnIsNotWaitedFor() async {
        let owner = "WorkLineWaitForTargetTests.hideSettled", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let earlier = Task { @MainActor in (thing.shown, thing.hideSettled) = (false, true); return 0 }
        let found = await line.waitForTarget(after: earlier, listed: { thing.shown || thing.hideSettled }, mayReturn: { asked.count += 1; return true }, limit: Self.long, owner: owner)
        #expect(found && !thing.shown, "found \(found), shown \(thing.shown) (want found and not shown)")
        #expect(line.targetsHiddenAtTheirTurn == 0 && asked.count == 0,
                "\(line.targetsHiddenAtTheirTurn) second waits and \(asked.count) questions if the thing can come back (want 0 and 0: the hide settled)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: there was no wait)")
    }

    /// The thing is hidden at its turn, it can come back, and the limit is at its end (a limit of 0): no second wait.
    @Test func aThingHiddenAtItsTurnIsNotWaitedForWhenTheLimitIsAtItsEnd() async {
        let owner = "WorkLineWaitForTargetTests.limitAtItsEnd", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let earlier = Task { @MainActor in thing.shown = false; return 0 }
        let found = await line.waitForTarget(after: earlier, listed: { thing.shown }, mayReturn: { asked.count += 1; return true }, limit: .zero, owner: owner)
        #expect(found && !thing.shown, "found \(found), shown \(thing.shown) (want found, as the thing was listed inside the limit, and not shown)")
        #expect(line.targetsHiddenAtTheirTurn == 0, "\(line.targetsHiddenAtTheirTurn) second waits (want 0: the limit was at its end)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: there was no wait)")
    }

    /// The thing is hidden at its turn and can come back, and after the second wait began it can no longer come back
    /// (in the app: the close that hid a tab ended, and the tab is gone). The second wait ends then: one second wait,
    /// and the timer did not fire. The works behind this one do not wait for the limit.
    @Test func aThingThatCanNoLongerComeBackEndsTheSecondWait() async {
        let owner = "WorkLineWaitForTargetTests.canNoLongerComeBack", before = Self.fires(owner)
        let line = WorkLine<Int>(), thing = Thing(shown: true), asked = Asked()
        let earlier = Task { @MainActor in thing.shown = false; return 0 }
        let found = await line.waitForTarget(after: earlier, listed: { thing.shown }, mayReturn: {
            asked.count += 1
            if asked.count == 1 { Task { @MainActor in thing.canReturn = false } } // runs when the function is in its second wait
            return thing.canReturn
        }, limit: .seconds(20), owner: owner)
        #expect(found && !thing.shown, "found \(found), shown \(thing.shown) (want found, as the thing was listed inside the limit, and not shown)")
        #expect(line.targetsHiddenAtTheirTurn == 1, "\(line.targetsHiddenAtTheirTurn) second waits (want 1: the thing could come back at its turn)")
        #expect(Self.fires(owner) == before, "the limit's timer fired \(Self.fires(owner) - before) times (want 0: the second wait ends when the thing can no longer come back, not at its limit)")
    }
}
