import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

@MainActor
struct PendingWorkspaceRowsTests {
    private static func row(_ id: String, window: String = "window") -> PendingWorkspaceRows.Row {
        PendingWorkspaceRows.Row(id: id, window: window, machine: .local, title: "", slot: nil, byDefault: nil)
    }

    private static func section() -> SidebarSection {
        SidebarSection(kind: .machine(.init(id: .local, name: "This Mac", kind: .local)), nodes: [])
    }

    @Test func listedRowsAreRemovedWithoutLeavingSkeletons() {
        let rows = PendingWorkspaceRows()
        rows.add(Self.row("first"))
        // A second press promotes the first row immediately, matching key-repeat
        // behavior without waiting for the grace timer.
        rows.add(Self.row("second"))
        #expect(rows.rows(in: "window").map(\.id) == ["first", "second"])

        rows.forget(in: "window", listed: ["first"]) { _ in false }

        #expect(rows.rows(in: "window").map(\.id) == ["second"])
        let shown = PendingWorkspaceRows.adding(rows.rows(in: "window"), to: [Self.section()], home: nil)
        #expect(shown.flatMap(\.workspaces).map(\.id.rawValue) == ["second"])
    }

    @Test func pendingRowsKeepPressOrderAtBottom() {
        let rows = PendingWorkspaceRows()
        rows.add(Self.row("first"))
        rows.add(Self.row("second"))

        let shown = PendingWorkspaceRows.adding(rows.rows(in: "window"), to: [Self.section()], home: nil)

        #expect(shown.flatMap(\.workspaces).map(\.id.rawValue) == ["first", "second"])

    private static let machine = MachineID("test-machine")
    private static func sections() -> [SidebarRowSection] {
        let machine = SidebarMachine(id: Self.machine, name: "Test", kind: .local)
        let existing = SidebarWorkspace(id: WorkspaceID("existing"), machineID: Self.machine, title: "Existing")
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(existing)])]
    }

    private static func row(_ id: String, title: String = "") -> PendingWorkspaceRows.Row {
        PendingWorkspaceRows.Row(id: id, window: "window", machine: Self.machine, title: title, slot: nil, byDefault: nil)
    }

    private static func workspaceIDs(_ sections: [SidebarRowSection]) -> [String] {
        sections.flatMap(\.workspaces).map(\.id.rawValue)
    }

    @Test func pendingRowsKeepPressOrderAndSettleOutOfThePlaceholderProjection() {
        let rows = [Self.row("new-1", title: "One"), Self.row("new-2", title: "Two")]
        let first = PendingWorkspaceRows.adding(rows, to: Self.sections(), home: nil)
        let second = PendingWorkspaceRows.adding(rows, to: Self.sections(), home: nil)

        #expect(Self.workspaceIDs(first) == ["existing", "new-1", "new-2"])
        #expect(Self.workspaceIDs(first) == Self.workspaceIDs(second))
        #expect(first.flatMap(\.workspaces).dropFirst().allSatisfy { $0.rowState == .placeholder })

        let settled = PendingWorkspaceRows.withoutPlaceholders(first)
        #expect(Self.workspaceIDs(settled) == ["existing"])
        #expect(settled.flatMap(\.workspaces).allSatisfy { $0.rowState == .live })
    }
}
