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
    }
}
