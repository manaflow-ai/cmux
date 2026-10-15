import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Group by Status's elbow children (Debug `sidebar.statusElbow`; Leo 2026-10-14): a child agent
/// session's row (one an agent or coordinator started) hangs off its parent row with the CLI elbow
/// connector `⎿`, as a tool result hangs off its call in Claude Code's output, not an indent. The
/// child sits directly under its parent, in the parent's bucket, so the tree reads. Off, the list
/// is the plain status list.
@MainActor @Suite(.serialized) struct SidebarStatusElbowTests {
    struct Sidebar {
        let model: SidebarModel
        let view: SidebarView
        var rows: [SidebarWorkspace]

        init(_ rows: [SidebarWorkspace], elbows: Bool) {
            self.rows = rows
            let design = DesignSettings()
            SidebarStatusGroupingTests.toggles(status: true, elbows: elbows)
            model = SidebarModel(sections: Self.sections(rows))
            model.applyListPreferences(design.sidebarSections.withStatusDebugToggles())
            view = SidebarView(model: model, design: design)
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        static func sections(_ rows: [SidebarWorkspace]) -> [SidebarSection] {
            [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: rows.map { .workspace($0) })]
        }

        /// What the row feed does when a row's parent changes: a patch, else the whole list again.
        mutating func parent(_ id: String, _ parent: String?) {
            guard let i = rows.firstIndex(where: { $0.id.rawValue == id }) else { return }
            rows[i].parentWorkspace = parent.map(WorkspaceID.init)
            if !model.patchWorkspaces([rows[i]]) { model.setSections(Self.sections(rows)) }
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        /// The list top to bottom: a header's spoken label, or a workspace's id, `⎿ ` before a row
        /// that draws the elbow connector.
        var drawn: [String] {
            view.list.displayed.rows.compactMap { row in
                guard case let .workspace(id) = row.key else { return view.list.rowViews[row.key]?.accessibilityLabel() }
                let elbow = view.list.rowViews[row.key]?.subviews.contains { $0 is SidebarElbowView && !$0.isHidden } == true
                return (elbow ? SidebarElbowView.glyph + " " : "") + id.rawValue
            }
        }
    }

    static func agent(_ id: String, _ activity: StatusIndicatorState, parent: String? = nil) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, rowKind: .agent, activity: activity, agentBrand: "claude")
        row.parentWorkspace = parent.map(WorkspaceID.init)
        return row
    }

    /// A coordinator at work, a worker it started that asks a question, an unrelated agent, a shell.
    static let rows = [
        SidebarWorkspace(id: WorkspaceID("shell"), title: "shell"),
        agent("coord", .working(progress: nil)),
        agent("other", .working(progress: nil)),
        agent("worker", .waiting(kind: nil), parent: "coord"),
    ]

    @Test func aChildHangsOffItsParentWithTheElbow() {
        defer { SidebarStatusGroupingTests.resetToggles() }
        let sidebar = Sidebar(Self.rows, elbows: true)
        // The worker asks, so its tree sits under Needs you, the coordinator above it.
        #expect(sidebar.drawn == [
            "Needs you, 2 workspaces", "coord", "⎿ worker",
            "Working, 1 workspaces", "other",
            "No agent, 1 workspaces", "shell",
        ], "\(sidebar.drawn)")
    }

    /// Review of #20905: a child that asks under a finished coordinator, with Done folded, was
    /// drawn nowhere. Its tree goes under Needs you, which never folds.
    @Test func aChildThatAsksNeverHidesInAFoldedSection() {
        defer { SidebarStatusGroupingTests.resetToggles() }
        let rows = [Self.agent("coord", .success), Self.agent("worker", .waiting(kind: nil), parent: "coord"),
                    Self.agent("done", .success)]
        let sidebar = Sidebar(rows, elbows: true)
        sidebar.model.toggleStatusBucket(.done)
        sidebar.view.list.reload(animated: false)
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(sidebar.drawn == ["Needs you, 2 workspaces", "coord", "⎿ worker", "Done, 1 workspaces"], "\(sidebar.drawn)")
    }

    /// Review of #20905: a row update that keeps the row's place (a new title) patched the row's
    /// content in place and dropped its elbow.
    @Test func aChildKeepsItsElbowWhenItsRowUpdates() {
        defer { SidebarStatusGroupingTests.resetToggles() }
        let sidebar = Sidebar(Self.rows, elbows: true)
        var worker = Self.rows[3]
        worker.title = "worker, renamed"
        #expect(sidebar.model.patchWorkspaces([worker]), "a new title moves no row")
        sidebar.view.layoutSubtreeIfNeeded()
        #expect(sidebar.drawn.prefix(3) == ["Needs you, 2 workspaces", "coord", "⎿ worker"], "\(sidebar.drawn)")
    }

    @Test func offTheListIsThePlainStatusList() {
        defer { SidebarStatusGroupingTests.resetToggles() }
        let sidebar = Sidebar(Self.rows, elbows: false)
        #expect(sidebar.drawn == [
            "Needs you, 1 workspaces", "worker",
            "Working, 2 workspaces", "coord", "other",
            "No agent, 1 workspaces", "shell",
        ], "\(sidebar.drawn)")
    }

    @Test func aRowMovesUnderTheParentItGains() {
        defer { SidebarStatusGroupingTests.resetToggles() }
        var sidebar = Sidebar(Self.rows, elbows: true)
        sidebar.parent("worker", nil)
        #expect(sidebar.drawn.prefix(2) == ["Needs you, 1 workspaces", "worker"], "\(sidebar.drawn)")

        sidebar.parent("worker", "other")
        #expect(sidebar.drawn.prefix(3) == ["Needs you, 2 workspaces", "other", "⎿ worker"], "\(sidebar.drawn)")
    }
}
