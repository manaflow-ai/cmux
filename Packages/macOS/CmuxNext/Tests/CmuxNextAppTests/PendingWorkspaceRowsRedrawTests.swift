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
