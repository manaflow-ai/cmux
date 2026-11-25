@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// A new workspace's row draws in the press's own turn: each window's sidebar redraws in the turn a
/// pending row comes or goes, not on a later rows pass that walks every workspace (Leo, 2026-10-18:
/// "sidebar still doesnt open new workspaces fast enough"; perf-gate.py new_workspaces gates it live).
@MainActor
struct PendingWorkspaceRowsRedrawTests {
    private final class Owner {}

    private func row(_ id: String, window: String) -> PendingWorkspaceRows.Row {
        let machine = CmuxNextSidebar.MachineID.local
        return .init(id: id, window: window, machine: machine,
                     face: SidebarMapping.shared.creatingRow(id: id, machine: machine, name: "workspace-1", opensPage: true),
                     slot: nil, byDefault: nil)
    }

    @Test func addAndRemoveRedrawInTheSameTurn() {
        let rows = PendingWorkspaceRows(), owner = Owner()
        var drawn: [[String]] = []
        rows.redraws.add(owner) { drawn.append(rows.rows(in: "w1").map(\.id)) }
        rows.add(row("ws-1", window: "w1"), name: "workspace-1")
        #expect(drawn == [["ws-1"]])
        rows.remove("ws-1")
        #expect(drawn == [["ws-1"], []])
        withExtendedLifetime(owner) {}
    }

    @Test func forgetRedrawsOnlyWhenItDropsARow() {
        let rows = PendingWorkspaceRows(), owner = Owner()
        var redraws = 0
        rows.add(row("ws-1", window: "w1"), name: "workspace-1")
        rows.redraws.add(owner) { redraws += 1 }
        rows.forget(in: "w1", listed: [], held: { _ in true }, elsewhere: { _ in false })
        #expect(redraws == 0)
        rows.forget(in: "w1", listed: ["ws-1"], held: { _ in true }, elsewhere: { _ in false })
        #expect(redraws == 1)
        #expect(rows.rows(in: "w1").isEmpty)
        withExtendedLifetime(owner) {}
    }

    /// An instant chat open's stand-in is in the store from the turn its row is added. When its create and its close reach
    /// the store in one apply, no rows pass sees the daemon's workspace (diag6, job 1925a643: 5 of 40 close-before-answer
    /// runs; the close went out 1.9 ms after create-workspace answered, before any pass). Its row must still go once the
    /// store no longer holds the workspace: it left a row the window lists for nothing, which refused moving workspaces out.
    @Test func anUnpinnedCreatesRowGoesOnceItsWorkspaceIsGoneWithNoPassBetween() {
        let rows = PendingWorkspaceRows()
        rows.add(creating: "ws-1", window: "w1", machine: .local, name: "workspace-1", opensPage: true, slot: nil, byDefault: nil, unpinned: true)
        // The stand-in is held: the row stays.
        rows.forget(in: "w1", listed: [], held: { _ in true }, elsewhere: { _ in false })
        #expect(rows.rows(in: "w1").map(\.id) == ["ws-1"])
        // Created and closed in one apply: the next pass finds the workspace gone, never having listed it.
        rows.forget(in: "w1", listed: [], held: { _ in false }, elsewhere: { _ in false })
        #expect(rows.rows(in: "w1").isEmpty, "the row of a closed instant open stayed")
    }

    /// Cmd-N's row is not marked at the add: before its daemon workspace lists, a pass that does not hold it (its stand-in
    /// not inserted yet) must not drop it.
    @Test func aCmdNRowStaysUntilItsWorkspaceWasSeen() {
        let rows = PendingWorkspaceRows()
        rows.add(creating: "ws-2", window: "w1", machine: .local, name: "workspace-2", opensPage: true, slot: nil, byDefault: nil)
        rows.forget(in: "w1", listed: [], held: { _ in false }, elsewhere: { _ in false })
        #expect(rows.rows(in: "w1").map(\.id) == ["ws-2"])
    }

    @Test func aGoneOwnerIsNotRedrawn() {
        let redraws = SidebarRedraws()
        var count = 0
        do {
            let owner = Owner()
            redraws.add(owner) { count += 1 }
            withExtendedLifetime(owner) { redraws.run() }
        }
        redraws.run()
        #expect(count == 1)
    }
}
