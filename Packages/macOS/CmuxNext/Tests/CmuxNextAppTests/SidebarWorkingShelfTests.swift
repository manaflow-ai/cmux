import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// The working shelf (`sidebar.workingShelf`; Leo's feature map 2026-11-23, item 16: "Chats waiting on subagents,
/// checks or watches fold into one row and return when they need you"): a chat whose turn ended and that waits on
/// background work folds into "Working (N)" at the end of its list, before every other fold; working, asking, unread
/// and quiet chats stay; the wait's end brings it back. The rule is Rust's (`sidebar_shelf_plan`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarWorkingShelfTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let looseFold = SidebarDoneFoldID(section: section, group: nil, kind: .working)
    static let settledFold = SidebarDoneFoldID(section: section, group: nil, kind: .settled)

    static func chat(_ id: String, waits: Int = 0, chip: SidebarPriorityEntry.State? = nil, working: Bool = false,
                     unread: Bool = false, done: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(timeIntervalSince1970: 1_800_000_000),
                                   agentWorking: working, kind: .harness, unread: unread ? .dot : .none)
        row.agentChip = chip
        row.backgroundWaits = waits
        if done { row.taskStatus = .done }
        return row
    }

    static func terminal(_ id: String) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id, lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
        row.backgroundWaits = 1
        return row
    }

    /// working (waits 1), asking (1), job (1), quiet (0), unread (1), term (1, not a chat), marked (Done, 1), two (2).
    static func sections() -> [SidebarSection] {
        let nodes: [SidebarNode] = [
            .workspace(chat("working", waits: 1, working: true)), .workspace(chat("asking", waits: 1, chip: .needsYou)),
            .workspace(chat("job", waits: 1)), .workspace(chat("quiet")), .workspace(chat("unread", waits: 1, unread: true)),
            .workspace(terminal("term")), .workspace(chat("marked", waits: 1, done: true)), .workspace(chat("two", waits: 2)),
        ]
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    static func keys(_ o: SidebarLayoutOptions, sections: [SidebarSection] = sections()) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func model(shelves: Bool = true, sections: [SidebarSection] = sections()) -> SidebarModel {
        let model = SidebarModel(sections: sections)
        model.shelvesWaiting = shelves
        return model
    }

    @Test func theRuleShelvesOnlyChatsWaitingOnBackgroundWork() {
        #expect(Self.model().shelvedChats() == [WorkspaceID("job"), WorkspaceID("two")])
    }

    @Test func offShelvesNothingAndDrawsEveryRowInPlace() {
        let model = Self.model(shelves: false)
        #expect(model.shelvedChats().isEmpty)
        let o = model.rowOptions()
        #expect(o.shelved.isEmpty)
        #expect(!Self.keys(o).contains(.doneFold(Self.looseFold)))
    }

    @Test func shelvedChatsFoldIntoOneWorkingRowThatCountsAndOpens() throws {
        var o = Self.model().rowOptions()
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        let row = try #require(layout.row(for: .doneFold(Self.looseFold)))
        #expect(row.childCount == 2)
        #expect(row.isCollapsed)
        #expect(!Self.keys(o).contains(Self.w("job")))
        o.openDoneFolds = [Self.looseFold]
        let keys = Self.keys(o)
        let fold = try #require(keys.firstIndex(of: .doneFold(Self.looseFold)))
        #expect(Array(keys[(fold + 1)...].prefix(2)) == [Self.w("job"), Self.w("two")])
    }

    @Test func theWorkingRowComesBeforeTheSettledRow() throws {
        let model = Self.model()
        model.settlesFinished = true
        var o = model.rowOptions()
        o.openDoneFolds = [Self.looseFold, Self.settledFold]
        let keys = Self.keys(o)
        let working = try #require(keys.firstIndex(of: .doneFold(Self.looseFold)))
        let settled = try #require(keys.firstIndex(of: .doneFold(Self.settledFold)))
        #expect(working < settled)
        // A seen chat waiting on work draws once, on the shelf, not under Settled.
        let job = try #require(keys.firstIndex(of: Self.w("job")))
        #expect(working < job && job < settled)
        #expect(keys.filter { $0 == Self.w("job") }.count == 1)
    }

    @Test func theActiveChatStaysInPlace() {
        var o = Self.model().rowOptions()
        o.activeWorkspaceID = WorkspaceID("job")
        #expect(Self.keys(o).contains(Self.w("job")))
    }

    /// The done-when: a chat waiting on a 60 s background job folds, and comes back when the job ends (acpmux drops
    /// `backgroundWaits` to 0 and sends the chat the end, which starts a turn).
    @Test func aChatWaitingOnABackgroundJobFoldsAndComesBackWhenItEnds() {
        let waiting = Self.chat("job", waits: 1)
        #expect(SidebarModel.movesRows(from: Self.chat("job", waits: 1, working: true), to: waiting, groupsByFolder: false,
                                       shelves: true))
        #expect(SidebarModel.movesRows(from: waiting, to: Self.chat("job"), groupsByFolder: false, shelves: true))
        #expect(SidebarModel.movesRows(from: waiting, to: Self.chat("job", waits: 0, working: true), groupsByFolder: false,
                                       shelves: true))
        // One more wait keeps it on the shelf: no move. The setting off moves nothing.
        #expect(!SidebarModel.movesRows(from: waiting, to: Self.chat("job", waits: 2), groupsByFolder: false, shelves: true))
        #expect(!SidebarModel.movesRows(from: waiting, to: Self.chat("job"), groupsByFolder: false, shelves: false))

        let ended = [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.chat("job"))])]
        #expect(Self.model(sections: ended).shelvedChats().isEmpty)
    }

    @Test func aPinnedChatNeverShelves() {
        var sections = Self.sections()
        sections.insert(SidebarSection(kind: .pinned, nodes: [.workspace(Self.chat("pinnedJob", waits: 1))]), at: 0)
        #expect(!Self.model(sections: sections).shelvedChats().contains(WorkspaceID("pinnedJob")))
    }

    @Test func theLaneReadsBackgroundWaitsFromTheSummary() {
        let lane = AgentActivityLane.of(summary: ["sessionId": "s1", "lane": ["state": "idle"], "backgroundWaits": 2, "gitBranch": "lane/working-shelf-r1"])
        #expect(lane?.backgroundWaits == 2)
        #expect(lane?.branch == "lane/working-shelf-r1")
        #expect(AgentActivityLane.of(summary: ["sessionId": "s1", "lane": ["state": "idle"]])?.backgroundWaits == 0)
    }

    @Test func theSettingDefaultsOff() {
        #expect(SidebarSectionsPreferences().workingShelf == false)
    }
}
