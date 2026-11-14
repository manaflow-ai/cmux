import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// SIDEBAR INSERT 2 (profile at feat 8d8a0e9d03b5, cmux21, macOS 27, 120 Hz, 8 Cmd-N: the key turn's list reload of the
/// create's stand-in row was 10 ms at 50 rows and 17 ms at 200; `SidebarLayout.make` 1.1 -> 4.6 ms, the apply's runs
/// 0.1 -> 1.6 ms). Cmd-N draws the new workspace's row at the press (`PendingWorkspaceRows`, rowState `.creating`): the
/// sections gain that one loose row and the selection moves to it. The list laid every row out again for it. CLAUDE.md:
/// a change is O(changed items), never O(session). The insert now splices the one row into the layout it shows.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCreateInsertScalingTests {
    struct Harness {
        let sidebar: SidebarView
        let model: SidebarModel
        let window: NSWindow
        let rows: [SidebarNode]
    }

    static let created = WorkspaceID("ci-new")

    /// `count` loose workspaces in one machine section (`extra` nodes after them), the selection on the second row.
    static func make(_ count: Int, extra: [SidebarNode] = [], groupsByComputer: Bool = false) -> Harness {
        _ = NSApplication.shared
        let rows = (0..<count).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ci-\($0)"), title: "workspace \($0)")) } + extra
        let model = SidebarModel(sections: sections(rows), activeWorkspaceID: WorkspaceID("ci-1"))
        model.groupsByComputer = groupsByComputer
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

    static func sections(_ nodes: [SidebarNode]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    /// The press's set: the create's stand-in row at `index`, the selection on it (as Cmd-N's redraw does in one turn).
    /// Returns the sidebar counters of that set and the render after it.
    @discardableResult
    static func insert(_ h: Harness, at index: Int, selects: Bool = true) -> [String: Int] {
        var nodes = h.rows
        nodes.insert(.workspace(SidebarWorkspace(id: created, title: "new workspace", rowState: .creating)), at: index)
        _ = SidebarPerfCounters.report(reset: true)
        h.model.setSections(sections(nodes))
        if selects { h.model.activeWorkspaceID = created }
        h.sidebar.renderNow()
        return SidebarPerfCounters.report(reset: true)
    }

    /// What a full layout of the model draws now: the shown layout must be exactly it.
    static func fullLayout(_ h: Harness) -> SidebarLayout {
        let list = h.sidebar.list
        return SidebarLayout.make(sections: list.listSections, metrics: list.metrics, options: list.options(includeGap: true))
    }

    @Test func insertingACreatedRowLaysOutOneRowAt50Or200() {
        var laidOut: [Int: Int] = [:]
        for count in [50, 200] {
            let h = Self.make(count)
            defer { h.window.close() }
            let counts = Self.insert(h, at: 2)
            laidOut[count] = counts["layout_rows"] ?? 0
            let list = h.sidebar.list
            #expect(list.displayed.row(for: .workspace(Self.created)) != nil, "rows \(count): the new row is not listed")
            #expect(list.rowViews[.workspace(Self.created)] != nil, "rows \(count): the new row has no view")
            #expect(list.workspaces[Self.created]?.rowState == .creating)
            #expect(list.displayed == Self.fullLayout(h), "rows \(count): the shown layout is not the model's")
        }
        // The brief's seam: the rows laid out per insert stay the same as the list grows (the new row only).
        #expect(laidOut[50] == laidOut[200], "rows laid out per insert grow with the list: \(laidOut)")
        #expect(laidOut[200] == 1, "rows laid out per insert: \(laidOut)")
    }

    /// The splice draws what a full layout draws, wherever the row lands: first, in the middle, last, before a group,
    /// above the "Done (N)" row, under a machine header, and with the selection staying where it was.
    @Test(arguments: [0, 3, 12, 13])
    func anInsertShowsTheFullLayout(at index: Int) {
        let group = SidebarGroup(id: GroupID("ci-g"), name: "group", workspaces: [
            SidebarWorkspace(id: WorkspaceID("ci-g0"), title: "member 0"), SidebarWorkspace(id: WorkspaceID("ci-g1"), title: "member 1"),
        ])
        var done = SidebarWorkspace(id: WorkspaceID("ci-done"), title: "done")
        done.taskStatus = .done
        // 10 loose rows, the group (node 10), a loose row (11), a done row (12): an insert at 13 lands above "Done (1)".
        let extra: [SidebarNode] = [.group(group), .workspace(SidebarWorkspace(id: WorkspaceID("ci-after"), title: "after")), .workspace(done)]
        for (selects, byComputer) in [(true, false), (false, false), (true, true)] {
            let h = Self.make(10, extra: extra, groupsByComputer: byComputer)
            defer { h.window.close() }
            Self.insert(h, at: index, selects: selects)
            let list = h.sidebar.list
            #expect(list.displayed.row(for: .workspace(Self.created)) != nil)
            #expect(list.displayed == Self.fullLayout(h), "insert at \(index), selects \(selects), by computer \(byComputer)")
            // A second create right after the first (Cmd-N held) splices on the spliced layout.
            var nodes = h.model.sections[0].nodes
            nodes.insert(.workspace(SidebarWorkspace(id: WorkspaceID("ci-new-2"), title: "new 2", rowState: .creating)), at: index)
            h.model.setSections([SidebarSection(kind: h.model.sections[0].kind, nodes: nodes)])
            if selects { h.model.activeWorkspaceID = WorkspaceID("ci-new-2") }
            h.sidebar.renderNow()
            #expect(list.displayed == Self.fullLayout(h), "second insert at \(index), selects \(selects), by computer \(byComputer)")
        }
    }

    /// An archived group leaves its list for "Archive (N)" at the bottom (`splittingArchive`): opened, its header row
    /// there is no place for a row inserted right before its node (review of #37139).
    @Test func anInsertBeforeAnArchivedGroupStaysInItsList() {
        var group = SidebarGroup(id: GroupID("ci-ag"), name: "archived", workspaces: [
            SidebarWorkspace(id: WorkspaceID("ci-a0"), title: "member 0"), SidebarWorkspace(id: WorkspaceID("ci-a1"), title: "member 1"),
        ])
        group.isArchived = true
        let h = Self.make(10, extra: [.group(group), .workspace(SidebarWorkspace(id: WorkspaceID("ci-after"), title: "after"))])
        defer { h.window.close() }
        h.sidebar.list.openDoneFolds.insert(.archive)
        h.sidebar.list.reload(animated: false)
        Self.insert(h, at: 10)
        let list = h.sidebar.list
        #expect(list.displayed.row(for: .workspace(Self.created)) != nil)
        #expect(list.displayed == Self.fullLayout(h), "the row went under Archive")
    }

    /// An archived group keeps its place in its list while it holds the selection (`splittingArchive`): a create that
    /// moves the selection out of it sends the group to the Archive (review of #37139).
    @Test func anInsertThatTakesTheSelectionFromAnArchivedGroupArchivesIt() {
        var group = SidebarGroup(id: GroupID("ci-sg"), name: "archived", workspaces: [
            SidebarWorkspace(id: WorkspaceID("ci-s0"), title: "member 0"), SidebarWorkspace(id: WorkspaceID("ci-s1"), title: "member 1"),
        ])
        group.isArchived = true
        let h = Self.make(10, extra: [.group(group)])
        defer { h.window.close() }
        h.model.activeWorkspaceID = WorkspaceID("ci-s0")
        h.sidebar.renderNow()
        #expect(h.sidebar.list.displayed.row(for: .group(GroupID("ci-sg"))) != nil, "the group holding the selection is listed")
        Self.insert(h, at: 3)
        #expect(h.sidebar.list.displayed == Self.fullLayout(h), "the group stayed in its list")
    }
}
