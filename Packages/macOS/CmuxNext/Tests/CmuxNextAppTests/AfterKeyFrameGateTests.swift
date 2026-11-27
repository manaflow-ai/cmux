import CmuxNextWakeups
import Testing

/// ``AfterKeyFrameGate`` (TERMINAL CREATE COST): a stand-in's content waits for exactly one committed frame, once.
@MainActor @Suite struct AfterKeyFrameGateTests {
    @Test func aStandInWaitsForItsKeysFrameOnceThenNever() {
        var afterFrame: [@MainActor () -> Void] = []
        let gate = AfterKeyFrameGate { afterFrame.append($0) }
        var shown: [String] = []
        #expect(gate.waits("t1", standIn: true, exists: false) { shown.append("first"); return true }, "the key's turn makes no content")
        #expect(gate.waits("t1", standIn: true, exists: false) { shown.append("latest"); return true }, "a second ask in that turn waits too")
        #expect(afterFrame.count == 1, "one wait per stand-in")
        afterFrame.forEach { $0() }
        #expect(shown == ["latest"], "the latest asker shows it again once the frame committed")
        #expect(!gate.waits("t1", standIn: true, exists: false) { true }, "after the frame the content is made")
        #expect(afterFrame.count == 1, "never a second wait for the same stand-in")
    }

    @Test func contentThatExistsOrIsNoStandInsNeverWaits() {
        var afterFrame: [@MainActor () -> Void] = []
        let gate = AfterKeyFrameGate { afterFrame.append($0) }
        #expect(!gate.waits("t1", standIn: false, exists: false) { true })
        #expect(!gate.waits("t2", standIn: true, exists: true) { true })
        #expect(afterFrame.isEmpty)
    }

    @Test func aStandInNobodyShowsOrThatClosedLeavesNothingBehind() {
        var afterFrame: [@MainActor () -> Void] = []
        let gate = AfterKeyFrameGate { afterFrame.append($0) }
        var shown: [String] = []
        _ = gate.waits("t1", standIn: true, exists: false) { shown.append("t1"); return false }
        _ = gate.waits("t2", standIn: true, exists: false) { shown.append("t2"); return true }
        gate.forget("t2") // closed before its frame
        afterFrame.forEach { $0() }
        #expect(shown == ["t1"], "a closed stand-in is not shown again")
        #expect(gate.waits("t1", standIn: true, exists: false) { true }, "nothing showed t1: a later show waits for its own frame again")
    }
}
