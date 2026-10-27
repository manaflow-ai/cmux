import CmuxNextDaemon
import Foundation
@testable import CmuxNextWorkspaceRepair
import Testing

/// Sidebar churn (moves, group changes, a status per workspace, at 10 Hz over
/// 400 workspaces) must not make the repair look at every workspace: it
/// examines a workspace only when that workspace gains or loses its last pane,
/// and still closes one whose last tab closed.
@MainActor struct EmptyWorkspaceRepairCostTests {
    final class Closed { var keys: [WorkspaceKey] = [] }

    static let count = 40

    static func workspace(_ n: Int, panes: Bool = true) -> WorkspaceSnapshot {
        let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(n)), layout: .leaf(PaneID(rawValue: UInt64(n))),
                                    panes: panes ? [PaneSnapshot(id: PaneID(rawValue: UInt64(n)))] : [])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(n)), key: WorkspaceKey(rawValue: "ws-\(n)"),
                                 name: "Workspace \(n)", screens: [screen])
    }

    static func paneClosed(workspace n: Int) throws -> DaemonEvent {
        let json = #"{"workspace": \#(n), "screen": \#(n), "pane": \#(n), "entity": {"id": \#(n)}}"#
        return .paneClosed(try JSONDecoder().decode(PaneDelta.self, from: Data(json.utf8)))
    }

    /// Runs the repair's posted follows (``RepairTurns``) and lets its decision tasks run.
    static func settle(_ turns: RepairTurns, _ done: () -> Bool = { false }) async {
        for _ in 0..<200 where !done() {
            turns.run()
            await Task.yield()
        }
    }

    @Test func movesAndChangesExamineNoWorkspaceAndALastTabCloseExaminesOne() async throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: (1...Self.count).map { Self.workspace($0) }))
        let closed = Closed(), turns = RepairTurns()
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in nil }, close: { closed.keys.append($0) },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { 1 }, isLive: { true }, on: turns.work)
        // The membership follow's first apply examines every workspace in the init's own turn.
        let settled = repair.visited
        #expect(settled >= Self.count, "the repair never looked at the workspaces")

        for step in 0..<10 {
            let n = Self.count - step
            store.apply(.workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: UInt64(n)), index: 0,
                                                       entity: Self.workspace(n), workspaceRevision: UInt64(11 + step))))
        }
        store.apply(.workspaceChanged(WorkspaceDelta(workspace: 3, index: nil, entity: Self.workspace(3), workspaceRevision: 21)))
        await Self.settle(turns)
        #expect(repair.visited - settled == 0, "11 moves and changes examined \(repair.visited - settled) workspaces")

        let beforeClose = repair.visited
        store.apply(try Self.paneClosed(workspace: 5))
        await Self.settle(turns) { !closed.keys.isEmpty }
        #expect(closed.keys == [WorkspaceKey(rawValue: "ws-5")])
        #expect(repair.visited - beforeClose <= 2, "one last-tab close examined \(repair.visited - beforeClose) workspaces")
    }

    /// p06-scheduler-339 (R-obs, rule 9): the pane follow is a ServiceObservation, not an ObservationStream task.
    /// A last-tab close is examined in one visible task after the change's turn (no window, no node: the
    /// close is a daemon side effect that runs while nothing shows).
    @Test func aLastTabCloseIsExaminedInOneVisibleTaskAfterTheChangesTurn() throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: [Self.workspace(1), Self.workspace(2)]))
        let closed = Closed(), turns = RepairTurns()
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in nil }, close: { closed.keys.append($0) },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { 1 }, isLive: { true }, on: turns.work)
        let before = repair.visited
        store.apply(try Self.paneClosed(workspace: 1))
        #expect(repair.visited == before, "the close was examined in the change's own turn")
        #expect(turns.work.postedCount(.visible) > 0, "the flip posted no visible task")
        turns.run()
        #expect(repair.visited == before + 1, "the visible task did not examine the emptied workspace once")
        #expect(repair.isSettling(WorkspaceKey(rawValue: "ws-1")), "the emptied workspace was not claimed for its close")
    }
}
