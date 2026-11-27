@testable import CmuxNextCloud
import CmuxNextDaemon
import Testing

/// The chats moving now (`ChatMoves`, through Rust's `moves::chat_moves`): what a sidebar drop knew stays when the run begins, the machine comes when
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

/// A moved row waits on its machine until the workspace it left closes, so it never slides back first.
@MainActor @Suite struct ChatMovesLandingTests {
    private static func tree(_ revision: UInt64, listed: Bool) -> DaemonTree {
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [PaneSnapshot(id: PaneID(rawValue: 1))])
        let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-1"), name: "Chat", screens: [screen])
        return DaemonTree(workspaceRevision: revision, workspaces: listed ? [workspace] : [])
    }

    @Test func aMovedRowStaysUntilItsWorkspaceCloses() async throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree(10, listed: true))
        let id = try #require(store.workspaces.first?.id)
        let moves = ChatMoves()
        moves.begin(tab: "t", workspace: id, travels: true, machine: "m-1", store: store)
        moves.landed(tab: "t")
        moves.end(tab: "t")
        #expect(moves.all["t"]?.landed == true)
        store.apply(snapshot: Self.tree(11, listed: false))
        for _ in 0..<200 where !moves.all.isEmpty { await Task.yield() }
        #expect(moves.all.isEmpty)
    }

    @Test func aRowThatStayedOrAFailedMoveEndsAtOnce() {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree(10, listed: true))
        let moves = ChatMoves()
        moves.begin(tab: "stayed", workspace: store.workspaces.first?.id, travels: false, machine: "m-1", store: store)
        moves.landed(tab: "stayed")
        moves.begin(tab: "failed", workspace: store.workspaces.first?.id, travels: true, machine: "m-1", store: store)
        moves.end(tab: "failed")
        #expect(moves.all.isEmpty)
    }
}
