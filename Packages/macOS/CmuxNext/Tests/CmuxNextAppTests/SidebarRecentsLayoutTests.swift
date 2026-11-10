import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Projects and Recents (`sidebar.groupBy` = recents): every group under one "Projects" header, the first five then
/// "Show N more", and every workspace in no group under one "Recents" header, the newest activity first (Lawrence
/// 2026-11-05: "similar thing in sidebar as chatgpt app ... projects/groups at the top, and show more, and you have
/// recents as well").
@MainActor @Suite(.serialized) struct SidebarRecentsLayoutTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let builder = SidebarMachine(id: MachineID("builder"), name: "Builder", kind: .ssh)
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func ws(_ id: String, minutesAgo: Double? = nil) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        row.lastActivity = minutesAgo.map { t0.addingTimeInterval(-$0 * 60) }
        return row
    }

    static func group(_ id: String, _ members: [SidebarWorkspace], parent: String? = nil) -> SidebarNode {
        var group = SidebarGroup(id: GroupID(id), name: id.uppercased(), color: .green, workspaces: members)
        if let parent {
            group.parent = GroupID(parent)
            group.depth = 1
        }
        return .group(group)
    }

    /// Loose a (10 min ago), b (never), c (1 min ago); group g: g1.
    static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(local), nodes: [
            .workspace(ws("a", minutesAgo: 10)), group("g", [ws("g1")]), .workspace(ws("b")), .workspace(ws("c", minutesAgo: 1)),
        ])]
    }

    static func options(_ by: SidebarGroupBy = .recents, active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.grouping.by = by
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions, _ sections: [SidebarSection] = sections()) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }
    static func g(_ id: String) -> SidebarRowKey { .group(GroupID(id)) }

    /// Seven groups g0...g6 of one member each, then loose x.
    static func manyGroups(_ count: Int = 7) -> [SidebarSection] {
        [SidebarSection(kind: .machine(local), nodes: (0..<count).map { group("g\($0)", [ws("m\($0)")]) } + [.workspace(ws("x"))])]
    }

    @Test func groupsListUnderProjectsThenLooseRowsUnderRecentsNewestFirst() {
        #expect(Self.keys(Self.options()) == [
            .listHeader(.projects), Self.g("g"), Self.w("g1"),
            .listHeader(.recents), Self.w("c"), Self.w("a"), Self.w("b"),
        ])
    }

    @Test func theHeadersCountTheirLists() throws {
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        #expect(try #require(layout.row(for: .listHeader(.projects))).childCount == 1)
        #expect(try #require(layout.row(for: .listHeader(.recents))).childCount == 3)
    }

    /// Every project lists, past five too (Leo 2026-11-10: "there's obviously no show more for like all projects"):
    /// each project caps its own chats instead.
    @Test func everyProjectListsWithNoShowMore() throws {
        let keys = Self.keys(Self.options(), Self.manyGroups())
        #expect(keys.filter { if case .group = $0 { true } else { false } } == (0..<7).map { Self.g("g\($0)") })
        #expect(!keys.contains(.showMore(.projects)))
        let layout = SidebarLayout.make(sections: Self.manyGroups(), metrics: .standard, options: Self.options())
        #expect(try #require(layout.row(for: .listHeader(.projects))).childCount == 7)
    }





    @Test func twoComputersShareOneProjectsAndOneRecents() {
        let sections = [
            SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a", minutesAgo: 5)), Self.group("g", [Self.ws("g1")])]),
            SidebarSection(kind: .machine(Self.builder), nodes: [.workspace(Self.ws("x", minutesAgo: 1)), Self.group("h", [Self.ws("h1")])]),
        ]
        var o = Self.options()
        o.flattensMachines = true
        #expect(Self.keys(o, sections) == [
            .listHeader(.projects), Self.g("g"), Self.w("g1"), Self.g("h"), Self.w("h1"),
            .listHeader(.recents), Self.w("x"), Self.w("a"),
        ])
    }

    @Test func noGroupsDrawsNoProjectsHeader() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), .workspace(Self.ws("b"))])]
        #expect(Self.keys(Self.options(), sections) == [.listHeader(.recents), Self.w("a"), Self.w("b")])
    }

    @Test func aFilterListsMatchesInPlace() {
        var o = Self.options()
        o.filterMatches = [WorkspaceID("a"), WorkspaceID("g1")]
        let keys = Self.keys(o)
        #expect(!keys.contains(.listHeader(.projects)) && !keys.contains(.listHeader(.recents)))
        #expect(keys.contains(Self.w("a")) && keys.contains(Self.w("g1")))
    }

    @Test func offDrawsTheListAsBefore() {
        let keys = Self.keys(Self.options(.none))
        #expect(!keys.contains(.listHeader(.projects)) && !keys.contains(.listHeader(.recents)))
        #expect(keys == [Self.w("a"), Self.g("g"), Self.w("g1"), Self.w("b"), Self.w("c")])
    }

    @Test func groupByStatusWinsOverRecents() {
        var o = Self.options()
        o.grouping.setByStatus(true)
        #expect(!Self.keys(o).contains(.listHeader(.recents)))
    }

    @Test func everyRowKeyAppearsOnce() {
        let keys = Self.keys(Self.options(), Self.manyGroups())
        #expect(Set(keys).count == keys.count)
    }
    /// The opened Archive lists every archived group: Recents never folds them behind a Show more it cannot draw.
    @Test func theOpenedArchiveListsEveryArchivedGroup() {
        let archived: [SidebarNode] = (0..<7).map { index in
            var member = Self.ws("a\(index)")
            member.isArchived = true
            var group = SidebarGroup(id: GroupID("z\(index)"), name: "Z\(index)", color: .green, workspaces: [member])
            group.isArchived = true
            return .group(group)
        }
        var o = Self.options()
        o.foldsDone = true
        o.openDoneFolds = [.archive]
        let keys = Self.keys(o, [SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("x"))] + archived)])
        #expect(keys.filter { if case .group = $0 { true } else { false } } == (0..<7).map { Self.g("z\($0)") })
        #expect(!keys.contains(.showMore(.projects)))
    }
}
