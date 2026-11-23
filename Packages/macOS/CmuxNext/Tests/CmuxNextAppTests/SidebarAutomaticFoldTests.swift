@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Automatic sessions (`sidebar.showAutomaticSessions`, off by default; Leo: "A LOT OF THESE SESSIONS ID IMAGINE DIDNT
/// NECESSSARILY NEED TO SHOW UP ON THE SIDE BY DEFAULT"): a session no person started and that is no chat's subagent
/// (its daemon recorded `created_by` kind `script`) folds into "Automatic (N)" at the end of its list; a person's rows
/// and subagents (kind `agent`) always show; the setting draws every row in place. The rule is Rust's
/// (`sidebar_automatic_plan`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarAutomaticFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let looseFold = SidebarDoneFoldID(section: section, group: nil, kind: .automatic)
    static let groupFold = SidebarDoneFoldID(section: section, group: GroupID("p"), kind: .automatic)

    static func row(_ id: String, by creator: SidebarCreator?, chip: SidebarPriorityEntry.State? = nil) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
        row.createdBy = creator
        row.agentChip = chip
        return row
    }

    /// Loose: a person's row, an unrecorded row, a script's row, a subagent, a script's row that asks, a second script
    /// row; group p: p1 a person's, p2 a script's.
    static func sections() -> [SidebarSection] {
        let group = SidebarGroup(id: GroupID("p"), name: "P", color: .green,
                                 workspaces: [row("p1", by: .person), row("p2", by: .script)])
        let nodes: [SidebarNode] = [
            .workspace(row("mine", by: .person)), .workspace(row("old", by: nil)), .workspace(row("cron", by: .script)),
            .workspace(row("sub", by: .agent)), .workspace(row("asks", by: .script, chip: .needsYou)),
            .workspace(row("hook", by: .script)), .group(group),
        ]
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    static func keys(_ o: SidebarLayoutOptions) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections(), metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func model(shows: Bool = false) -> SidebarModel {
        let model = SidebarModel(sections: sections())
        model.showsAutomaticSessions = shows
        return model
    }

    @Test func aScriptSessionThatIsNoSubagentFoldsByDefault() {
        #expect(Self.model().automaticSessions() == [WorkspaceID("cron"), WorkspaceID("hook"), WorkspaceID("p2")])
        #expect(Self.keys(Self.model().rowOptions()) == [
            Self.w("mine"), Self.w("old"), Self.w("sub"), Self.w("asks"),
            .group(GroupID("p")), Self.w("p1"), .doneFold(Self.groupFold),
            .doneFold(Self.looseFold),
        ])
    }

    @Test func theSettingShowsEveryAutomaticSessionInPlace() {
        let model = Self.model(shows: true)
        #expect(model.automaticSessions().isEmpty)
        let o = model.rowOptions()
        #expect(o.automatic.isEmpty)
        #expect(Self.keys(o) == [
            Self.w("mine"), Self.w("old"), Self.w("cron"), Self.w("sub"), Self.w("asks"), Self.w("hook"),
            .group(GroupID("p")), Self.w("p1"), Self.w("p2"),
        ])
    }

    @Test func personStartedRowsAndSubagentsAlwaysShow() {
        for shows in [false, true] {
            let keys = Self.keys(Self.model(shows: shows).rowOptions())
            for id in ["mine", "old", "sub", "p1"] { #expect(keys.contains(Self.w(id)), "\(id) shows=\(shows)") }
        }
    }

    @Test func theAutomaticRowCountsAndOpens() throws {
        var o = Self.model().rowOptions()
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        let row = try #require(layout.row(for: .doneFold(Self.looseFold)))
        #expect(row.childCount == 2)
        #expect(row.isCollapsed)
        o.openDoneFolds = [Self.looseFold]
        let keys = Self.keys(o)
        let fold = try #require(keys.firstIndex(of: .doneFold(Self.looseFold)))
        #expect(Array(keys[(fold + 1)...]) == [Self.w("cron"), Self.w("hook")])
    }

    @Test func theActiveAutomaticSessionStaysInPlace() {
        var o = Self.model().rowOptions()
        o.activeWorkspaceID = WorkspaceID("cron")
        #expect(Self.keys(o).firstIndex(of: Self.w("cron")) == 2)
    }

    @Test func aPinnedAutomaticSessionShows() {
        var sections = Self.sections()
        sections.insert(SidebarSection(kind: .pinned, nodes: [.workspace(Self.row("pinnedCron", by: .script))]), at: 0)
        let model = SidebarModel(sections: sections)
        #expect(!model.automaticSessions().contains(WorkspaceID("pinnedCron")))
    }

    @Test func askingOrChangingWhoMadeItMovesTheRow() {
        let cron = Self.row("cron", by: .script)
        let asks = Self.row("cron", by: .script, chip: .needsYou)
        #expect(SidebarModel.movesRows(from: cron, to: asks, groupsByFolder: false, automates: true))
        #expect(SidebarModel.movesRows(from: Self.row("x", by: nil), to: Self.row("x", by: .script), groupsByFolder: false, automates: true))
        var renamed = cron
        renamed.title = "renamed"
        #expect(!SidebarModel.movesRows(from: cron, to: renamed, groupsByFolder: false, automates: true))
        // A person's row that asks moves nothing here: it never folds as automatic.
        #expect(!SidebarModel.automaticMoves(from: Self.row("m", by: .person), to: Self.row("m", by: .person, chip: .needsYou)))
        #expect(Self.model().movesRows(from: cron, to: Self.row("cron", by: .script, chip: .needsYou)))
    }

    @Test func theSettingDefaultsToHidden() {
        #expect(SidebarSectionsPreferences().showAutomaticSessions == false)
        #expect(SidebarSectionsSetting.showAutomaticSessionsDefault == false)
    }
}
