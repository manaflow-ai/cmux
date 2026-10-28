import CmuxNextTabs
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

    private func make(_ recorder: Recorder) -> PageDecidedCloses<Pane, [TabID]> {
        PageDecidedCloses(prepare: { _, ids in recorder.prepared.append(ids); return ids },
                          send: { prepared, _, user in recorder.sent.append(prepared); recorder.userCloses.append(user) })
    }

    @Test func pagesThatCloseJoinOneSend() {
        let recorder = Recorder(), left = Pane(), right = Pane()
        let closes = make(recorder)
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
    }

    @Test func aPageThatKeepsItsTabDoesNotHoldTheRest() async throws {
        let recorder = Recorder(), pane = Pane()
        let closes = make(recorder)
        closes.deadline = .milliseconds(20)
        closes.begin(closing: [(pane, ["a"])], deciding: [(pane, ["b"])], userClose: false)
        let deadline = ContinuousClock.now + .seconds(10)
        while recorder.sent.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.sent == [[["a"]]], "the rest closes at the deadline")
        #expect(!closes.isWaiting)
        // The page closes later (after Stay, the person closes it again): its own close.
        #expect(closes.absorb([(pane, ["b"])]).map(\.ids) == [["b"]])
    }
}
