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

    /// Lets the repair's observation hops run (each is one main-actor job).
    static func settle(_ done: () -> Bool = { false }) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func movesAndChangesExamineNoWorkspaceAndALastTabCloseExaminesOne() async throws {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: (1...Self.count).map { Self.workspace($0) }))
        let closed = Closed()
        let repair = EmptyWorkspaceRepair(store: store, create: { _ in nil }, close: { closed.keys.append($0) },
                                          cause: { _ in .tabClosed }, canCreate: { true }, epoch: { 1 }, isLive: { true })
        await Self.settle { repair.visited >= Self.count }
        let settled = repair.visited
        #expect(settled >= Self.count, "the repair never looked at the workspaces")

        for step in 0..<10 {
            let n = Self.count - step
            store.apply(.workspaceMoved(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: UInt64(n)), index: 0,
                                                       entity: Self.workspace(n), workspaceRevision: UInt64(11 + step))))
        }
        store.apply(.workspaceChanged(WorkspaceDelta(workspace: 3, index: nil, entity: Self.workspace(3), workspaceRevision: 21)))
        await Self.settle()
        #expect(repair.visited - settled == 0, "11 moves and changes examined \(repair.visited - settled) workspaces")

        let beforeClose = repair.visited
        store.apply(try Self.paneClosed(workspace: 5))
        await Self.settle { !closed.keys.isEmpty }
        #expect(closed.keys == [WorkspaceKey(rawValue: "ws-5")])
        #expect(repair.visited - beforeClose <= 2, "one last-tab close examined \(repair.visited - beforeClose) workspaces")
    }
}
