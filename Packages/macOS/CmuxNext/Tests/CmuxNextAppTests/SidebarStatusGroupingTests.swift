import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// Group by Status (Debug `sidebar.groupByStatus`, off by default; Leo 2026-10-14, #20905): rows sit under the
/// Priority view's states, in its tier order and with its words (Needs you, Done, Failed, CI failing, Working, Idle),
/// from the state the row already carries from the Priority classifier (`SidebarWorkspace.agentChip`, the row's
/// working mark). Inside a section rows keep their manual order. A row moves as its state changes, except the row the
/// person is on, which stays put until another row is active. Off, the list is the list as before.
@MainActor @Suite(.serialized) struct SidebarStatusGroupingTests {
    struct Sidebar {
        let model: SidebarModel
        let view: SidebarView
        var rows: [SidebarWorkspace]

        init(_ rows: [SidebarWorkspace], active: WorkspaceID? = nil) {
            self.rows = rows
            model = SidebarModel(sections: Self.sections(rows), activeWorkspaceID: active)
            view = SidebarView(model: model, design: DesignSettings())
            view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
            redraw()
        }

        static func sections(_ rows: [SidebarWorkspace]) -> [CmuxNextSidebar.SidebarSection] {
            [CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: rows.map { .workspace($0) })]
        }

        /// What the sidebar does after a change: it reads its settings (the Debug toggle included) and lays out again.
        func redraw() {
            view.renderNow()
            view.list.reload(animated: false)
            view.layoutSubtreeIfNeeded()
        }

        /// What the row feed does with a state change: a patch, else the whole list again.
        mutating func report(_ id: String, chip: SidebarPriorityEntry.State?, working: Bool = false) {
            guard let i = rows.firstIndex(where: { $0.id.rawValue == id }) else { return }
            (rows[i].agentChip, rows[i].agentWorking) = (chip, working)
            if !model.patchWorkspaces([rows[i]]) { model.setSections(Self.sections(rows)) }
            redraw()
        }

        func activate(_ id: String) {
            model.activeWorkspaceID = WorkspaceID(id)
            redraw()
        }

        /// The list top to bottom: a header's spoken label, or a workspace's id.
        var drawn: [String] {
            view.list.displayed.rows.compactMap { row in
                if case let .workspace(id) = row.key { return id.rawValue }
                return view.list.rowViews[row.key]?.accessibilityLabel()
            }
        }
    }

    /// The Debug toggle `sidebar.groupByStatus`, as Debug Settings sets it; nil is its default.
    static func toggle(_ on: Bool?) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.groupByStatus.key, on.map { .bool($0) })
    }

    /// A row as the row feed maps it: `chip` is the Priority view's chip (`SidebarLaneStatus.chip`), `working` its
    /// working mark.
    static func agent(_ id: String, _ chip: SidebarPriorityEntry.State? = nil, working: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, rowKind: .agent, agentWorking: working, agentBrand: "codex")
        row.agentChip = chip
        return row
    }

    /// In manual order: the sections below never reorder them.
    static let rows = [
        SidebarWorkspace(id: WorkspaceID("shell"), title: "shell"),
        agent("build", working: true),
        agent("ask", .needsYou),
        agent("shipped", .done),
        agent("broke", .failed),
        agent("red", .ciFailing),
        agent("gone", .lost),
        agent("asks", .needsYou),
    ]

    @Test func rowsSitUnderThePriorityViewsStatesInManualOrder() {
        defer { Self.toggle(nil) }
        Self.toggle(true)
        let sidebar = Sidebar(Self.rows)
        #expect(sidebar.drawn == [
            "Needs you, 2 workspaces", "ask", "asks",
            "Done, 1 workspaces", "shipped",
            "Failed, 2 workspaces", "broke", "gone",
            "CI failing, 1 workspaces", "red",
            "Working, 1 workspaces", "build",
            "Idle, 1 workspaces", "shell",
        ], "\(sidebar.drawn)")
    }

    @Test func offByDefaultTheListIsAsBefore() {
        defer { Self.toggle(nil) }
        Self.toggle(nil)
        let sidebar = Sidebar(Self.rows)
        #expect(sidebar.drawn == Self.rows.map(\.id.rawValue), "\(sidebar.drawn)")
        #expect(!sidebar.model.locksReorder, "off, a drag reorders as before")
    }

    @Test func aRowMovesWhenItsStateChangesAndTheActiveRowWaits() {
        defer { Self.toggle(nil) }
        Self.toggle(true)
        var sidebar = Sidebar(Self.rows, active: WorkspaceID("shipped"))
        // Inside a section rows keep their manual order: build sits above ask in the list.
        sidebar.report("build", chip: .needsYou)
        #expect(sidebar.drawn.prefix(4) == ["Needs you, 3 workspaces", "build", "ask", "asks"], "\(sidebar.drawn)")

        // The row the person is on starts a turn: it stays under Done while they are on it.
        sidebar.report("shipped", chip: nil, working: true)
        #expect(sidebar.drawn.contains("Done, 1 workspaces"), "\(sidebar.drawn)")
        #expect(!sidebar.drawn.contains("Working, 1 workspaces"), "\(sidebar.drawn)")

        sidebar.activate("shell")
        #expect(!sidebar.drawn.contains("Done, 1 workspaces"), "\(sidebar.drawn)")
        #expect(sidebar.drawn.suffix(4) == ["Working, 1 workspaces", "shipped", "Idle, 1 workspaces", "shell"], "\(sidebar.drawn)")
    }

    @Test func aSectionFoldsButNeedsYouNeverDoes() {
        defer { Self.toggle(nil) }
        Self.toggle(true)
        let sidebar = Sidebar(Self.rows)
        sidebar.model.toggleStatusSection(.idle)
        sidebar.model.toggleStatusSection(.needsYou)
        sidebar.redraw()
        #expect(sidebar.drawn.suffix(3) == ["Working, 1 workspaces", "build", "Idle, 1 workspaces"], "\(sidebar.drawn)")
        #expect(sidebar.drawn.prefix(3) == ["Needs you, 2 workspaces", "ask", "asks"], "\(sidebar.drawn)")
    }

    /// Review of #20905: turning the toggle off forgets the held row and the folds, so turning it on again starts fresh.
    @Test func turningItOffForgetsFoldsAndTheHeldRow() {
        defer { Self.toggle(nil) }
        Self.toggle(true)
        var sidebar = Sidebar(Self.rows, active: WorkspaceID("shipped"))
        sidebar.model.toggleStatusSection(.idle)
        sidebar.report("shipped", chip: nil, working: true) // held under Done
        Self.toggle(false)
        sidebar.redraw()
        #expect(sidebar.drawn == Self.rows.map(\.id.rawValue), "\(sidebar.drawn)")
        Self.toggle(true)
        sidebar.redraw()
        #expect(sidebar.drawn.suffix(5) == ["Working, 2 workspaces", "build", "shipped", "Idle, 1 workspaces", "shell"],
                "\(sidebar.drawn)")
    }

    /// The Done fold (`sidebar.doneFold`, on by default) folds workspaces marked Done in the plain list; inside status
    /// sections it does not apply, so a workspace marked Done shows under its Priority state.
    @Test func aWorkspaceMarkedDoneShowsUnderItsStateNotTheDoneFold() {
        defer { Self.toggle(nil) }
        var rows = Self.rows
        rows[1].taskStatus = .done // build, working
        Self.toggle(true)
        let sidebar = Sidebar(rows)
        #expect(sidebar.drawn.suffix(4) == ["Working, 1 workspaces", "build", "Idle, 1 workspaces", "shell"], "\(sidebar.drawn)")
        #expect(!sidebar.view.list.displayed.rows.contains { if case .doneFold = $0.key { true } else { false } })
    }

    /// Show more (`sidebar.groupRowLimit`) does not apply inside status sections, as the Done fold does not: a section
    /// of 14 rows with a limit of 10 lists all 14 and no "Show N more" row.
    @Test func aStatusSectionShowsEveryRowPastTheRowLimit() {
        let rows = (0..<14).map { Self.agent("w\($0)", working: true) }
        var o = SidebarLayoutOptions()
        o.rowLimit = 10
        o.foldsDone = true
        o.grouping.setByStatus(true)
        let keys = SidebarLayout.make(sections: Sidebar.sections(rows), metrics: .standard, options: o).rows.map(\.key)
        let expected: [SidebarRowKey] = [.status(.working)] + rows.map { SidebarRowKey.workspace($0.id) }
        #expect(keys == expected, "\(keys)")
        #expect(!keys.contains { if case .showMore = $0 { true } else { false } })
    }

    /// A status section's last row and the next section's header keep the row spacing alone, as under a group's last
    /// member (Leo 2026-10-21: "ALL THIS RELATIVELY UNNECESSARY SPACING AFTER GROUPS").
    @Test func aStatusSectionsLastRowAndTheNextHeaderKeepTheRowSpacing() throws {
        let m = SidebarLayoutMetrics.standard
        var o = SidebarLayoutOptions()
        o.grouping.setByStatus(true)
        let layout = SidebarLayout.make(sections: Sidebar.sections([Self.agent("build", working: true), SidebarWorkspace(id: WorkspaceID("shell"), title: "shell")]),
                                        metrics: m, options: o)
        let build = try #require(layout.row(for: .workspace(WorkspaceID("build"))))
        let idle = try #require(layout.row(for: .status(.idle)))
        #expect(abs(idle.y - build.maxY - m.rowSpacing) < 0.01, "the section's end adds \(idle.y - build.maxY - m.rowSpacing) pt to the row spacing")
    }

    /// The sections are the Priority classifier's (`AgentPriorityRanking.state` through `SidebarLaneStatus`), not one
    /// of the sidebar's own: acpmux lanes in, the rows the row feed maps, laid out under their states.
    @Test func theSectionsComeFromThePriorityClassifier() throws {
        defer { Self.toggle(nil) }
        let fixture = try SidebarRowStatusTests.Fixture()
        Self.toggle(true)
        let sidebar = Sidebar(fixture.rows())
        #expect(sidebar.drawn == [
            "Needs you, 1 workspaces", "waiting",
            "Done, 1 workspaces", "finished",
            "Failed, 1 workspaces", "failed",
            "Working, 1 workspaces", "working",
            "Idle, 1 workspaces", "idle",
        ], "\(sidebar.drawn)")
    }
}
