import Foundation
@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// A group's Sort (Leo 2026-11-03: "honestly i think we ought to be able to sort/filter the group alphabetically
/// or smth..."): the document stores it on the group (`extra.sort`), and `arrange` lists the group's workspaces
/// by name or by recent activity; Manual, the default, is the stored order.
@MainActor @Suite struct SidebarGroupSortTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }

    static func ws(_ id: String, _ title: String, active: TimeInterval? = nil, archived: Bool = false) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: WorkspaceID(id), title: title)
        workspace.lastActivity = active.map { now.addingTimeInterval($0) }
        workspace.isArchived = archived
        return workspace
    }

    static func titles(_ workspaces: [SidebarWorkspace]) -> [String] { workspaces.map(\.title) }

    // MARK: The order

    @Test func manualKeepsTheStoredOrder() {
        let members = [Self.ws("a", "zeta", active: 5), Self.ws("b", "Alpha"), Self.ws("c", "beta", active: 9)]
        #expect(Self.titles(SidebarGroupSort.manual.ordered(members)) == ["zeta", "Alpha", "beta"])
    }

    @Test func nameIsAToZIgnoringCaseWithNumbersByValue() {
        let members = [Self.ws("a", "ws-10"), Self.ws("b", "beta"), Self.ws("c", "ws-2"), Self.ws("d", "Alpha"), Self.ws("e", "Émile")]
        #expect(Self.titles(SidebarGroupSort.name.ordered(members)) == ["Alpha", "beta", "Émile", "ws-2", "ws-10"])
    }

    @Test func nameTiesKeepTheStoredOrder() {
        let members = [Self.ws("a", "same"), Self.ws("b", "same"), Self.ws("c", "aaa")]
        #expect(SidebarGroupSort.name.ordered(members).map(\.id.rawValue) == ["c", "a", "b"])
    }

    @Test func recentPutsTheLatestFirstAndNoActivityLast() {
        let members = [Self.ws("a", "old", active: -600), Self.ws("b", "none"), Self.ws("c", "new", active: 0),
                       Self.ws("d", "none too"), Self.ws("e", "mid", active: -60)]
        #expect(Self.titles(SidebarGroupSort.recent.ordered(members)) == ["new", "mid", "old", "none", "none too"])
    }

    @Test func pinnedStayFirstAndArchivedLast() {
        let members = [Self.ws("a", "c-archived", archived: true), Self.ws("b", "b"), Self.ws("c", "z-pinned"), Self.ws("d", "a")]
        let ordered = SidebarGroupSort.name.ordered(members) { $0.id.rawValue == "c" }
        #expect(Self.titles(ordered) == ["z-pinned", "a", "b", "c-archived"])
    }

    // MARK: The stored sort

    static func document(sort: String?) -> Data {
        let extra = sort.map { #", "extra": {"sort": "\#($0)"}"# } ?? ""
        return Data("""
        {"revision": "3",
         "sections": [{"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}],
         "items": [
           {"id": "g1", "section": "sec_m_s1", "order": "a", "body": {"type": "group", "name": "G"}\(extra)},
           {"id": "w1", "section": "sec_m_s1", "parent": "g1", "order": "b",
            "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "ws_1"}}}
         ]}
        """.utf8)
    }

    @Test func theWireSortReadsBack() throws {
        #expect(try SidebarDocRecords(document: Self.document(sort: "name")).items["g1"]?.sort == .name)
        #expect(try SidebarDocRecords(document: Self.document(sort: "recent")).items["g1"]?.sort == .recent)
        #expect(try SidebarDocRecords(document: Self.document(sort: nil)).items["g1"]?.sort == .manual)
        // A sort a newer build stores lists in the stored order here.
        #expect(try SidebarDocRecords(document: Self.document(sort: "size")).items["g1"]?.sort == .manual)
    }

    @Test func theSortTheMenuSendsIsWhatTheWireReads() {
        for sort in SidebarGroupSort.allCases { #expect(SidebarGroupSort(wire: sort.rawValue) == sort) }
    }

    // MARK: The arranged list

    static func projection(sort: SidebarGroupSort) -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_g": SidebarDocItem(id: "itm_g", section: machine, body: .group(name: "G", color: nil, icon: nil, collapsed: false), sort: sort),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, parent: "itm_g", body: .workspace(ref("ws-1"))),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_g", body: .workspace(ref("ws-2")), pinnedInGroup: true),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, parent: "itm_g", body: .workspace(ref("ws-3"))),
        ])
        let rows = [
            SidebarDocRow(key: "itm_g", kind: "group", section: machine, item: "itm_g"),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_g", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, parent: "itm_g", depth: 1, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, parent: "itm_g", depth: 1, item: "itm_3", ref: ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func raw() -> [SidebarSection] {
        let members = [ws("ws-2", "pinned"), ws("ws-1", "zulu", active: -60), ws("ws-3", "alpha", active: 0)]
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("itm_g"), name: "G", workspaces: members)),
        ])]
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    static func group(_ sections: [SidebarSection]) -> SidebarGroup? {
        for case .group(let group) in sections.flatMap(\.nodes) { return group }
        return nil
    }

    @Test func aSortedGroupListsItsWorkspacesInItsSort() throws {
        let byName = try #require(Self.group(Self.projection(sort: .name).arrange(Self.raw(), drag: Self.drag)))
        #expect(byName.sort == .name)
        #expect(Self.titles(byName.workspaces) == ["pinned", "alpha", "zulu"], "the member pinned in its group stays first")
        let byRecent = try #require(Self.group(Self.projection(sort: .recent).arrange(Self.raw(), drag: Self.drag)))
        #expect(Self.titles(byRecent.workspaces) == ["pinned", "alpha", "zulu"])
        let manual = try #require(Self.group(Self.projection(sort: .manual).arrange(Self.raw(), drag: Self.drag)))
        #expect(manual.sort == .manual)
        #expect(Self.titles(manual.workspaces) == ["pinned", "zulu", "alpha"])
    }

    @Test func backToManualClearsTheSortOnAnArrangedList() throws {
        // A fold passes the shown list back in: the old sort must not stay.
        let once = Self.projection(sort: .name).arrange(Self.raw(), drag: Self.drag)
        let again = try #require(Self.group(Self.projection(sort: .manual).arrange(once, drag: Self.drag)))
        #expect(again.sort == .manual)
    }

    @Test func aSortOnlyChangeShowsTheSameRowsAgain() {
        // The rows a sort lists are the same live rows: a pass that lists them again must still arrange them.
        let store = SidebarDocStore(remote: nil, mirror: nil)
        store.shown = Self.projection(sort: .manual)
        let model = SidebarModel(sections: [])
        model.docDrag = SidebarDocDrag(document: store, item: { Self.drag.item($0) }, section: { id in id == .machine(.local) ? Self.machine : nil },
                                       begin: { _ in [:] }, drop: { _, _ in })
        let rows = SidebarRows(model: model, document: { store })
        rows.show(Self.raw(), creating: ([], nil), unlessShown: true, elsewhere: [])
        model.setSections([]) // a marker: a skipped pass leaves it
        rows.show(Self.raw(), creating: ([], nil), unlessShown: true, elsewhere: [])
        #expect(model.sections.isEmpty, "the same rows and sorts showed again")
        store.shown = Self.projection(sort: .name)
        rows.show(Self.raw(), creating: ([], nil), unlessShown: true, elsewhere: [])
        #expect(Self.group(model.sections).map { Self.titles($0.workspaces) } == ["pinned", "alpha", "zulu"],
                "a change of a group's sort alone did not show again")
    }

    @Test func theEditorsSortRowReadsTheGroupsSort() {
        let items = SidebarGroupEditing.showingSort(SidebarGroupEditing.standardItems(), .recent)
        #expect(items.flatMap { $0 }.first { $0.id == SidebarGroupEditing.sortItem }?.shortcut == "Recent")
        #expect(items.flatMap { $0 }.filter { $0.id != SidebarGroupEditing.sortItem }.allSatisfy { $0.shortcut == nil })
    }
}
