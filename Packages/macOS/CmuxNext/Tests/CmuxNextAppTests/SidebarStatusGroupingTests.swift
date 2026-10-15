import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Group by Status (Debug `sidebar.groupByStatus`; Leo 2026-10-14, video 1/5 of the Claude Code
/// desktop release): rows sit under Needs you, Working, Done and No agent from each row's merged
/// status, whatever harness reports it, and move as that status changes, except the row the person
/// is on, which stays put until another row is active.
@MainActor @Suite(.serialized) struct SidebarStatusGroupingTests {
    struct Sidebar {
        let model: SidebarModel
        let view: SidebarView
        var rows: [SidebarWorkspace]

        init(_ rows: [SidebarWorkspace], active: WorkspaceID? = nil, sections: [SidebarSection]? = nil,
             status: Bool = true, elbows: Bool = false) {
            self.rows = rows
            let design = DesignSettings()
            SidebarStatusGroupingTests.toggles(status: status, elbows: elbows)
            model = SidebarModel(sections: sections ?? Self.sections(rows), activeWorkspaceID: active)
            // What the sidebar applies from what it observes (`SidebarView.observe`).
            model.applyListPreferences(design.sidebarSections.withStatusDebugToggles())
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

        /// Group by Status's marks on `id`'s row: the shown mark identifiers, nil without marks.
        func marks(_ id: String) -> Set<String>? {
            let row = view.list.rowViews[.workspace(WorkspaceID(id))]
            guard let marks = row?.subviews.first(where: {
                $0.identifier?.rawValue == "cmux.sidebar.workspace.statusMarks" && !$0.isHidden
            }) else { return nil }
            return Set(marks.subviews.filter { !$0.isHidden }.compactMap { $0.identifier?.rawValue })
        }

        /// The list top to bottom: a header's spoken label, or a workspace's id.
        var drawn: [String] {
            view.list.displayed.rows.compactMap { row in
                if case let .workspace(id) = row.key { return id.rawValue }
                return view.list.rowViews[row.key]?.accessibilityLabel()
            }
        }
    }

    /// The Debug toggles (`sidebar.groupByStatus`, `sidebar.statusElbow`), as Debug Settings sets
    /// them. Each test puts them back (`resetToggles`) before it returns.
    static func toggles(status: Bool, elbows: Bool) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.groupByStatus.descriptor.key, .bool(status))
        TunableStore.shared.set(SidebarTunables.statusElbow.descriptor.key, .bool(elbows))
    }

    static func resetToggles() {
        TunableStore.shared.set(SidebarTunables.groupByStatus.descriptor.key, nil)
        TunableStore.shared.set(SidebarTunables.statusElbow.descriptor.key, nil)
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
        defer { Self.resetToggles() }
        let sidebar = Sidebar(Self.rows)
        #expect(sidebar.drawn == [
            "Needs you, 2 workspaces", "ask", "broke",
            "Working, 1 workspaces", "build",
            "Done, 1 workspaces", "shipped",
            "No agent, 1 workspaces", "shell",
        ], "\(sidebar.drawn)")
    }

    @Test func aRowMovesWhenItsAgentAsksAndTheActiveRowWaits() {
        defer { Self.resetToggles() }
        var sidebar = Sidebar(Self.rows, active: WorkspaceID("shipped"))
        // Inside a section rows keep their list order: build sits above ask in the list.
        sidebar.report("build", .waiting(kind: nil))
        #expect(sidebar.drawn.prefix(4) == ["Needs you, 3 workspaces", "build", "ask", "broke"], "\(sidebar.drawn)")

        // The row the person is on starts a turn: it stays under Done while they are on it.
        sidebar.report("shipped", .working(progress: nil))
        #expect(sidebar.drawn.suffix(4) == ["Done, 1 workspaces", "shipped", "No agent, 1 workspaces", "shell"], "\(sidebar.drawn)")

        sidebar.activate("shell")
        #expect(!sidebar.drawn.contains("Done, 1 workspaces"), "\(sidebar.drawn)")
        #expect(sidebar.drawn.suffix(4) == ["Working, 1 workspaces", "shipped", "No agent, 1 workspaces", "shell"], "\(sidebar.drawn)")
    }

    /// Every row shows one status glyph, Needs you rows end with a warning, and each row says
    /// whether its session runs on this Mac or another computer; with the toggle off none of it draws.
    @Test func statusRowsMarkTheirStatusTheirUrgencyAndTheirComputer() {
        defer { Self.resetToggles() }
        let cloudRows = [Self.agent("remote", .working(progress: nil)), Self.agent("remoteAsk", .waiting(kind: nil))]
        let cloud = SidebarSection(kind: .machine(SidebarMachine(id: CmuxNextSidebar.MachineID("vm-1"), name: "cloud-a1", kind: .cloud)),
                                   nodes: cloudRows.map { .workspace($0) })
        let sections = Sidebar.sections(Self.rows) + [cloud]
        let sidebar = Sidebar(Self.rows + cloudRows, sections: sections)
        for row in Self.rows + cloudRows {
            let id = row.id.rawValue
            let marks = sidebar.marks(id) ?? []
            let glyphs = marks.intersection(["statusGlyph", "statusGlyph.quiet"])
            #expect(glyphs.count == 1, "\(id): \(marks)")
            let needsYou = ["ask", "broke", "remoteAsk"].contains(id)
            #expect(marks.contains("statusWarning") == needsYou, "\(id): \(marks)")
            let machine = id.hasPrefix("remote") ? "statusMachine.cloud" : "statusMachine.machine.local"
            #expect(marks.contains(machine), "\(id): \(marks)")
        }

        let plain = Sidebar(Self.rows + cloudRows, sections: sections, status: false)
        for row in Self.rows + cloudRows {
            #expect(plain.marks(row.id.rawValue) == nil, "\(row.id.rawValue)")
        }
    }
}
