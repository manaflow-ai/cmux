import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Group by Status (`sidebar.groupBy` `status`, Labs; Leo 2026-10-14, video 1/5 of the Claude Code
/// desktop release): rows sit under Needs you, Working, Done and No agent from each row's merged
/// status, whatever harness reports it, and move as that status changes, except the row the person
/// is on, which stays put until another row is active.
@MainActor @Suite(.serialized) struct SidebarStatusGroupingTests {
    struct Sidebar {
        let model: SidebarModel
        let view: SidebarView
        var rows: [SidebarWorkspace]

        init(_ rows: [SidebarWorkspace], active: WorkspaceID? = nil) {
            self.rows = rows
            let design = DesignSettings()
            design.sidebarSections.groupBy = .status
            model = SidebarModel(sections: Self.sections(rows), activeWorkspaceID: active)
            model.applyListPreferences(design.sidebarSections)
            view = SidebarView(model: model, design: design)
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        static func sections(_ rows: [SidebarWorkspace]) -> [SidebarSection] {
            [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: rows.map { .workspace($0) })]
        }

        /// What the row feed does with a status change: a patch, else the whole list again.
        mutating func report(_ id: String, _ activity: StatusIndicatorState) {
            guard let i = rows.firstIndex(where: { $0.id.rawValue == id }) else { return }
            rows[i].activity = activity
            if !model.patchWorkspaces([rows[i]]) { model.setSections(Self.sections(rows)) }
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        func activate(_ id: String) {
            model.activeWorkspaceID = WorkspaceID(id)
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        /// The list top to bottom: a header's spoken label, or a workspace's id.
        var drawn: [String] {
            view.list.displayed.rows.compactMap { row in
                if case let .workspace(id) = row.key { return id.rawValue }
                return view.list.rowViews[row.key]?.accessibilityLabel()
            }
        }
    }

    static func agent(_ id: String, _ activity: StatusIndicatorState) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: id, rowKind: .agent, activity: activity, agentBrand: "codex")
    }

    static let rows = [
        SidebarWorkspace(id: WorkspaceID("shell"), title: "shell"),
        agent("build", .working(progress: nil)),
        agent("ask", .waiting(kind: nil)),
        agent("shipped", .success),
        agent("broke", .error),
    ]

    @Test func rowsSitUnderTheirStatusWithCounts() {
        let sidebar = Sidebar(Self.rows)
        #expect(sidebar.drawn == [
            "Needs you, 2 workspaces", "ask", "broke",
            "Working, 1 workspaces", "build",
            "Done, 1 workspaces", "shipped",
            "No agent, 1 workspaces", "shell",
        ], "\(sidebar.drawn)")
    }

    @Test func aRowMovesWhenItsAgentAsksAndTheActiveRowWaits() {
        var sidebar = Sidebar(Self.rows, active: WorkspaceID("shipped"))
        sidebar.report("build", .waiting(kind: nil))
        #expect(sidebar.drawn.prefix(4) == ["Needs you, 3 workspaces", "ask", "build", "broke"], "\(sidebar.drawn)")

        // The row the person is on starts a turn: it stays under Done while they are on it.
        sidebar.report("shipped", .working(progress: nil))
        #expect(sidebar.drawn.suffix(4) == ["Done, 1 workspaces", "shipped", "No agent, 1 workspaces", "shell"], "\(sidebar.drawn)")

        sidebar.activate("shell")
        #expect(!sidebar.drawn.contains("Done, 1 workspaces"), "\(sidebar.drawn)")
        #expect(sidebar.drawn.suffix(4) == ["Working, 1 workspaces", "shipped", "No agent, 1 workspaces", "shell"], "\(sidebar.drawn)")
    }
}
