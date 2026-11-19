@testable import CmuxNextCloud
import Testing

/// The chats moving now (`ChatMoves`): what a sidebar drop knew stays when the run begins, the machine comes when
/// the run picks it, the bar never runs back, and an end clears the move.
@MainActor @Suite struct ChatMovesTests {
    @Test func aDropsMachineStaysWhenTheRunBeginsWithoutOne() {
        let moves = ChatMoves()
        moves.begin(tab: "t", workspace: "w", travels: true, machine: "m-1")
        moves.begin(tab: "t", workspace: "other", travels: false, machine: nil)
        #expect(moves.all["t"] == ChatMoves.Move(workspace: "w", travels: true, machine: "m-1"))
    }

    @Test func theRunNamesTheMachineOnceItPicksOne() {
        let moves = ChatMoves()
        moves.begin(tab: "t", workspace: "w", travels: true, machine: nil)
        moves.reach(tab: "t", machine: "m-2")
        #expect(moves.all["t"]?.machine == "m-2")
        moves.reach(tab: "unknown", machine: "m-2")
        #expect(moves.all["unknown"] == nil)
    }

    @Test func theBarNeverRunsBackAndAnEndClearsTheMove() {
        let moves = ChatMoves()
        moves.begin(tab: "t", workspace: "w", travels: true, machine: "m-1")
        moves.show(tab: "t", line: "2 of 4", fraction: 0.5)
        moves.show(tab: "t", line: "3 of 4", fraction: 0.45)
        #expect(moves.all["t"]?.line == "3 of 4")
        #expect(moves.all["t"]?.fraction == 0.5)
        moves.show(tab: "t", line: "4 of 4", fraction: 7)
        #expect(moves.all["t"]?.fraction == 1)
        moves.end(tab: "t")
        #expect(moves.all.isEmpty)
    }
}
