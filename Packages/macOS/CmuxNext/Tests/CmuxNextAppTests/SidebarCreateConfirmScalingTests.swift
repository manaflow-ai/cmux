import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// SIDEBAR INSERT (film at feat 31bfd7d0f86, cmux21, 120 Hz: 15-21 missed refreshes per Cmd-N, 4-5 more at 200 rows
/// than at 50). Cmd-N draws the new workspace's row at the press (`PendingWorkspaceRows`, rowState `.creating`, in its
/// final look); when the daemon lists the workspace, the rows pass sets the sections again with the workspace's own row
/// in the same place. Only that row's content changed, but the set was structural: the list laid out every row again
/// (`SidebarLayout.make` and its apply, 2.8 ms at 50 rows, 5.8 ms at 200, xctrace on cmux21). CLAUDE.md: a change is
/// O(changed items), never O(session). The confirm now writes the one row in place, as a row patch does.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCreateConfirmScalingTests {
    struct Harness {
        let sidebar: SidebarView
        let model: SidebarModel
        let window: NSWindow
        let rows: [SidebarWorkspace]
    }

    static let created = WorkspaceID("cc-new")

    /// `count` loose workspaces in one machine section, the create's stand-in row third from the top (on screen).
    static func make(_ count: Int) -> Harness {
        _ = NSApplication.shared
        var rows = (0..<count).map { SidebarWorkspace(id: WorkspaceID("cc-\($0)"), title: "workspace \($0)") }
        rows.insert(SidebarWorkspace(id: created, title: "new workspace", rowState: .creating), at: 2)
        let model = SidebarModel(sections: sections(rows), activeWorkspaceID: WorkspaceID("cc-0"))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.list.pointerIsOverList = { _ in false } // a mini's pointer over the window holds a model change (calm reload)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return Harness(sidebar: sidebar, model: model, window: window, rows: rows)
    }

    static func sections(_ rows: [SidebarWorkspace]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))]
    }

    /// The rows pass that lists the created workspace: the same rows, the stand-in now the workspace's live row.
    /// Returns the sidebar counters of that set and the render after it.
    static func confirm(_ h: Harness) -> [String: Int] {
        let live = h.rows.map { $0.id == created ? SidebarWorkspace(id: created, title: "new workspace") : $0 }
        _ = SidebarPerfCounters.report(reset: true)
        h.model.setSections(sections(live))
        h.sidebar.renderNow()
        return SidebarPerfCounters.report(reset: true)
    }

    @Test func confirmingACreatedRowLaysOutNoRowAt50Or200() {
        var laidOut: [Int: Int] = [:]
        for count in [50, 200] {
            let h = Self.make(count)
            defer { h.window.close() }
            let counts = Self.confirm(h)
            laidOut[count] = counts["layout_rows"] ?? 0
            #expect(counts["list_reloads"] == 0, "rows \(count): the confirm laid the list out again: \(counts)")
            #expect(counts["row_patches"] == 1, "rows \(count): the confirm should patch the one row: \(counts)")
            // The workspace's own row shows: interactive, no longer the stand-in.
            #expect(h.model.workspace(Self.created)?.rowState == .live)
            #expect(h.sidebar.list.workspaces[Self.created]?.rowState == .live)
            #expect(h.sidebar.list.displayed.row(for: .workspace(Self.created)) != nil)
        }
        // The brief's seam: the rows laid out per confirm stay the same as the list grows (none).
        #expect(laidOut[50] == laidOut[200], "rows laid out per confirm grow with the list: \(laidOut)")
        #expect(laidOut[200] == 0, "rows laid out per confirm: \(laidOut)")
    }

    /// A pass that adds a row is structural still: the list lays out and shows the new row.
    @Test func aPassThatAddsARowStillLaysTheListOut() {
        let h = Self.make(50)
        defer { h.window.close() }
        var rows = h.rows
        rows.insert(SidebarWorkspace(id: WorkspaceID("cc-added"), title: "added"), at: 4)
        _ = SidebarPerfCounters.report(reset: true)
        h.model.setSections(Self.sections(rows))
        h.sidebar.renderNow()
        let counts = SidebarPerfCounters.report(reset: true)
        #expect(counts["list_reloads"] == 1, "\(counts)")
        #expect(h.sidebar.list.displayed.row(for: .workspace(WorkspaceID("cc-added"))) != nil)
    }
}
