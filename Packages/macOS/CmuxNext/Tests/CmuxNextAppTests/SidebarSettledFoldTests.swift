import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Settled chats (`sidebar.settleFinished`): a seen, finished agent chat folds into "Settled (N)" at the end of its
/// list, before the Done row; working, waiting, unread, failed and lost chats stay; Done and archived rows keep their
/// own folds; a new turn brings a chat back. The rule is Rust's (`sidebar_settle_plan`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSettledFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let looseFold = SidebarDoneFoldID(section: section, group: nil, kind: .settled)
    static let doneFold = SidebarDoneFoldID(section: section, group: nil)
    static let groupFold = SidebarDoneFoldID(section: section, group: GroupID("p"), kind: .settled)

    static func chat(_ id: String, chip: SidebarPriorityEntry.State? = nil, working: Bool = false, unread: Bool = false,
                     done: Bool = false, ran: Bool = true) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: ran ? Date(timeIntervalSince1970: 1_800_000_000) : nil,
                                   agentWorking: working, kind: .harness, unread: unread ? .dot : .none)
        row.agentChip = chip
        if done { row.taskStatus = .done }
        return row
    }

    static func terminal(_ id: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Loose: working, asking, read-finished, unread-finished, failed, lost, terminal, never-ran, read (Done-marked),
    /// read-finished; group p: p1 working, p2 read.
    static func sections() -> [SidebarSection] {
        let group = SidebarGroup(id: GroupID("p"), name: "P", color: .green,
                                 workspaces: [chat("p1", working: true), chat("p2")])
        let nodes: [SidebarNode] = [
            .workspace(chat("working", working: true)), .workspace(chat("asking", chip: .needsYou)),
            .workspace(chat("read")), .workspace(chat("unread", chip: .done)), .workspace(chat("failed", chip: .failed)),
            .workspace(chat("lost", chip: .lost)), .workspace(terminal("term")), .workspace(chat("fresh", ran: false)),
            .workspace(chat("marked", done: true)), .workspace(chat("read2", unread: false)), .group(group),
        ]
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    static func keys(_ o: SidebarLayoutOptions) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections(), metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func model(settles: Bool = true) -> SidebarModel {
        let model = SidebarModel(sections: sections())
        model.settlesFinished = settles
        return model
    }

    @Test func theRuleSettlesOnlySeenFinishedChats() {
        #expect(Self.model().settledChats() == [WorkspaceID("read"), WorkspaceID("read2"), WorkspaceID("p2")])
    }

    @Test func offSettlesNothingAndDrawsEveryRowInPlace() {
        let model = Self.model(settles: false)
        #expect(model.settledChats().isEmpty)
        let o = model.rowOptions()
        #expect(o.settled.isEmpty)
        #expect(!Self.keys(o).contains(.doneFold(Self.looseFold)))
    }

    @Test func settledChatsFoldBeforeTheDoneRow() {
        var o = Self.model().rowOptions()
        o.foldsDone = true
        #expect(Self.keys(o) == [
            Self.w("working"), Self.w("asking"), Self.w("unread"), Self.w("failed"), Self.w("lost"), Self.w("term"), Self.w("fresh"),
            .group(GroupID("p")), Self.w("p1"), .doneFold(Self.groupFold),
            .doneFold(Self.looseFold), .doneFold(Self.doneFold),
        ])
    }

    @Test func theSettledRowCountsAndOpens() throws {
        var o = Self.model().rowOptions()
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        let row = try #require(layout.row(for: .doneFold(Self.looseFold)))
        #expect(row.childCount == 2)
        #expect(row.isCollapsed)
        o.openDoneFolds = [Self.looseFold]
        let keys = Self.keys(o)
        let fold = try #require(keys.firstIndex(of: .doneFold(Self.looseFold)))
        #expect(Array(keys[(fold + 1)...].prefix(2)) == [Self.w("read"), Self.w("read2")])
    }

    @Test func theActiveChatStaysInPlace() {
        var o = Self.model().rowOptions()
        o.activeWorkspaceID = WorkspaceID("read")
        let keys = Self.keys(o)
        #expect(keys.firstIndex(of: Self.w("read")) == 2)
    }

    @Test func aNewTurnOrAnUnreadAnswerMovesTheRowBack() {
        let model = Self.model()
        let old = Self.chat("read")
        #expect(SidebarModel.movesRows(from: old, to: Self.chat("read", working: true), groupsByFolder: false, settles: true))
        #expect(SidebarModel.movesRows(from: old, to: Self.chat("read", chip: .done), groupsByFolder: false, settles: true))
        #expect(SidebarModel.movesRows(from: old, to: Self.chat("read", chip: .needsYou), groupsByFolder: false, settles: true))
        // A fact the rule does not read (the title) moves nothing; with the setting off nothing settles.
        var renamed = old
        renamed.title = "renamed"
        #expect(!SidebarModel.movesRows(from: old, to: renamed, groupsByFolder: false, settles: true))
        #expect(!SidebarModel.movesRows(from: old, to: Self.chat("read", working: true), groupsByFolder: false, settles: false))
        #expect(model.movesRows(from: old, to: Self.chat("read", working: true)))
    }

    @Test func archiveSettledNamesWhatStaysAndWhy() {
        let plan = Self.model().settleArchivePlan()
        #expect(plan.archive == [WorkspaceID("read"), WorkspaceID("read2"), WorkspaceID("p2")])
        #expect(plan.unread == [WorkspaceID("unread")])
        #expect(plan.failed == [WorkspaceID("failed")])
        #expect(plan.lost == [WorkspaceID("lost")])
        #expect(plan.busy == [WorkspaceID("working"), WorkspaceID("asking"), WorkspaceID("p1")])
    }

    @Test func aPinnedChatNeverSettles() {
        var sections = Self.sections()
        sections.insert(SidebarSection(kind: .pinned, nodes: [.workspace(Self.chat("pinnedRead"))]), at: 0)
        let model = SidebarModel(sections: sections)
        model.settlesFinished = true
        #expect(!model.settledChats().contains(WorkspaceID("pinnedRead")))
    }

    @Test func theSettingParsesAndDefaultsOff() {
        #expect(SidebarSectionsPreferences().settleFinished == false)
    }
}
