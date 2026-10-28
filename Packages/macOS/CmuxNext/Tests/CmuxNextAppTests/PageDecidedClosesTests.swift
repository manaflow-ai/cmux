import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// `PageDecidedCloses`: a close of several tabs that waits for pages deciding their own close sends
/// every tab in ONE close (one Reopen Closed step), and a page that never closes does not hold the rest.
@MainActor @Suite struct PageDecidedClosesTests {
    final class Pane {}

    final class Recorder {
        var prepared: [[TabID]] = []
        var sent: [[[TabID]]] = []
        var userCloses: [Bool] = []
    }

    private func make(_ recorder: Recorder, _ rig: MainDeadlineRig) -> PageDecidedCloses<Pane, [TabID]> {
        PageDecidedCloses(prepare: { _, ids in recorder.prepared.append(ids); return ids },
                          send: { prepared, _, user in recorder.sent.append(prepared); recorder.userCloses.append(user) },
                          deadlines: rig.deadlines)
    }

    @Test func pagesThatCloseJoinOneSend() {
        let recorder = Recorder(), left = Pane(), right = Pane(), rig = MainDeadlineRig()
        let closes = make(recorder, rig)
        closes.begin(closing: [(left, ["a", "c"])], deciding: [(left, ["b"]), (right, ["d"])], userClose: true)
        #expect(recorder.prepared == [["a", "c"]], "the tabs that do not wait leave their strip at once")
        #expect(recorder.sent.isEmpty && closes.isWaiting)

        // An unrelated close passes through; a page's own close is taken.
        let rest = closes.absorb([(left, ["b", "x"])])
        #expect(rest.map(\.ids) == [["x"]])
        #expect(recorder.sent.isEmpty, "one page still decides")

        #expect(closes.absorb([(right, ["d"])]).isEmpty)
        #expect(recorder.sent == [[["a", "c"], ["b"], ["d"]]], "every tab goes in one close")
        #expect(recorder.userCloses == [true])
        #expect(!closes.isWaiting)
        #expect(closes.absorb([(right, ["d"])]).map(\.ids) == [["d"]], "a finished gesture takes nothing")
        #expect(!rig.hasArmedWake, "a finished gesture kept its deadline's wake")
    }

    /// The gesture's bound is a `visible` deadline on the app's placer (R-timer): nothing goes
    /// before it, and the rest closes at it, no sooner.
    @Test func aPageThatKeepsItsTabDoesNotHoldTheRest() {
        let recorder = Recorder(), pane = Pane(), rig = MainDeadlineRig()
        let closes = make(recorder, rig)
        closes.begin(closing: [(pane, ["a"])], deciding: [(pane, ["b"])], userClose: false)
        #expect(rig.hasArmedWake, "the gesture armed no deadline")
        rig.advance(by: .seconds(1))
        rig.fireAtNow()
        #expect(recorder.sent.isEmpty, "the rest closed before the deadline")
        rig.fireAndRun()
        #expect(rig.elapsed >= 2, "the rest closed \(rig.elapsed) s in")
        #expect(recorder.sent == [[["a"]]], "the rest closes at the deadline")
        #expect(!closes.isWaiting)
        // The page closes later (after Stay, the person closes it again): its own close.
        #expect(closes.absorb([(pane, ["b"])]).map(\.ids) == [["b"]])
    }
}
