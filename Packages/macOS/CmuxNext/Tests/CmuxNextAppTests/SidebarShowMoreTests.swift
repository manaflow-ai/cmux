@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A group or list longer than `sidebar.groupRowLimit` shows its first rows, the ones that need you and the active
/// one, then a "Show N more" row that lists the rest (Leo's sidebar organization, slice S5).
@MainActor @Suite(.serialized) struct SidebarShowMoreTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let groupList = SidebarDoneFoldID(section: section, group: GroupID("g"))
    static let looseList = SidebarDoneFoldID(section: section, group: nil)

    static func ws(_ id: String, needsYou: Bool = false, done: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        if needsYou { row.agentChip = .needsYou }
        if done { row.taskStatus = .done }
        return row
    }

    /// Group g: m0 ... m(count - 1); `needsYou` and `done` mark members by index.
    static func sections(count: Int = 14, needsYou: Set<Int> = [], done: Set<Int> = []) -> [SidebarSection] {
        let members = (0..<count).map { ws("m\($0)", needsYou: needsYou.contains($0), done: done.contains($0)) }
        let group = SidebarGroup(id: GroupID("g"), name: "G", color: .green, workspaces: members)
        return [SidebarSection(kind: .machine(machine), nodes: [.group(group)])]
    }

    static func options(limit: Int = 10, open: Set<SidebarDoneFoldID> = [], active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.rowLimit = limit
        o.openShowMore = open
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions, _ sections: [SidebarSection]) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func members(_ indices: some Sequence<Int>) -> [SidebarRowKey] { indices.map { .workspace(WorkspaceID("m\($0)")) } }

    @Test func aLongGroupShowsItsFirstRowsThenShowMore() throws {
        let sections = Self.sections()
        #expect(Self.keys(Self.options(), sections) == [.group(GroupID("g"))] + Self.members(0..<10) + [.showMore(Self.groupList)])
        let row = try #require(SidebarLayout.make(sections: sections, metrics: .standard, options: Self.options()).row(for: .showMore(Self.groupList)))
        #expect(row.childCount == 4)
        #expect(row.isCollapsed)
        #expect(row.isLastInGroup)
    }

    @Test func rowsThatNeedYouAndTheActiveOneStayShown() {
        let sections = Self.sections(needsYou: [12])
        #expect(Self.keys(Self.options(active: "m11"), sections)
            == [.group(GroupID("g"))] + Self.members(0..<10) + Self.members([11, 12]) + [.showMore(Self.groupList)])
    }

    @Test func anOpenListShowsEveryRowThenShowFewer() throws {
        let o = Self.options(open: [Self.groupList])
        #expect(Self.keys(o, Self.sections()) == [.group(GroupID("g"))] + Self.members(0..<14) + [.showMore(Self.groupList)])
        let row = try #require(SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o).row(for: .showMore(Self.groupList)))
        #expect(row.childCount == 0)
        #expect(!row.isCollapsed)
    }

    @Test func oneRowOverTheLimitShowsWithoutTheRow() {
        #expect(Self.keys(Self.options(), Self.sections(count: 11)) == [.group(GroupID("g"))] + Self.members(0..<11))
    }

    @Test func zeroTurnsItOff() {
        #expect(Self.keys(Self.options(limit: 0), Self.sections()) == [.group(GroupID("g"))] + Self.members(0..<14))
    }

    /// Done workspaces fold first and count toward neither the limit nor "Show N more".
    @Test func doneWorkspacesFoldBelowShowMore() {
        let sections = Self.sections(count: 14, done: [0, 1])
        #expect(Self.keys(Self.options(), sections)
            == [.group(GroupID("g"))] + Self.members(2..<12) + [.showMore(Self.groupList), .doneFold(Self.groupList)])
    }

    @Test func looseRowsLimitToo() {
        let nodes: [SidebarNode] = (0..<12).map { .workspace(Self.ws("m\($0)")) }
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: nodes)]
        #expect(Self.keys(Self.options(), sections) == Self.members(0..<10) + [.showMore(Self.looseList)])
    }

    /// A section's limit counts its loose workspaces only: its groups always show, with what they hold.
    @Test func groupsPastASectionsLimitStayShown() {
        let loose: [SidebarNode] = (0..<12).map { .workspace(Self.ws("m\($0)")) }
        let a = SidebarGroup(id: GroupID("a"), name: "A", color: .green, workspaces: [Self.ws("a1")])
        let b = SidebarGroup(id: GroupID("b"), name: "B", color: .green, workspaces: [Self.ws("b1")])
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: loose + [.group(a), .group(b)])]
        #expect(Self.keys(Self.options(active: "b1"), sections) == Self.members(0..<10) + [
            .group(GroupID("a")), .workspace(WorkspaceID("a1")), .group(GroupID("b")), .workspace(WorkspaceID("b1")),
            .showMore(Self.looseList),
        ])
    }

    @Test func aLongGroupIsNotSpliced() {
        let o = Self.options()
        let shown = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        guard case var .group(group) = Self.sections()[0].nodes[0] else { Issue.record("no group"); return }
        group.isCollapsed = true
        #expect(shown.folding(group, collapsed: true, in: Self.sections()[0], metrics: .standard, options: o) == nil)
    }

    @Test func theRowSaysHowManyMore() {
        #expect(Strings.showMore(4).contains("4"))
        #expect(!Strings.showFewer.isEmpty)
    }
}
