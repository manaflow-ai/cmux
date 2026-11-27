import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// One collapsed "Archive (N)" row at the bottom of the sidebar holds every archived workspace and every group whose
/// workspaces are all archived (or that is archived itself); no list draws an "Archived (N)" row of its own
/// (Lawrence 19197: "i see a ton of archived ... this doesnt look very clean ... maybe we can move completely archived
/// groups into archive as well").
@MainActor @Suite(.serialized) struct SidebarArchiveSectionTests {
    static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let builder = SidebarMachine(id: MachineID("builder"), name: "Builder", kind: .ssh)

    static func ws(_ id: String, archived: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        row.isArchived = archived
        return row
    }

    static func group(_ id: String, _ members: [SidebarWorkspace], archived: Bool = false) -> SidebarNode {
        var group = SidebarGroup(id: GroupID(id), name: id.uppercased(), color: .green, workspaces: members)
        group.isArchived = archived
        return .group(group)
    }

    /// Loose a, c and b (archived); group g: g1, g2 (archived); group h (archived itself): h1, h2; group k (every
    /// workspace archived, the group not): k1, k2. Archived rows list last, as the document keeps them.
    static func sections() -> [SidebarSection] {
        [SidebarSection(kind: .machine(local), nodes: [
            .workspace(ws("a")), .workspace(ws("c")),
            group("g", [ws("g1"), ws("g2", archived: true)]),
            .workspace(ws("b", archived: true)),
            group("h", [ws("h1", archived: true), ws("h2", archived: true)], archived: true),
            group("k", [ws("k1", archived: true), ws("k2", archived: true)]),
        ])]
    }

    static func options(open: Bool = false, active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        if open { o.openDoneFolds = [.archive] }
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions, _ sections: [SidebarSection] = sections()) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }
    static func g(_ id: String) -> SidebarRowKey { .group(GroupID(id)) }

    @Test func everythingArchivedLeavesForOneArchiveRowAtTheBottom() {
        #expect(Self.keys(Self.options()) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), .doneFold(.archive)])
    }

    @Test func noListDrawsItsOwnArchivedRow() {
        let keys = Self.keys(Self.options(open: true))
        #expect(!keys.contains { if case let .doneFold(fold) = $0 { fold.kind == .archived } else { false } })
    }

    @Test func theArchiveRowIsClosedByDefaultAndCountsEveryArchivedWorkspace() throws {
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        let row = try #require(layout.row(for: .doneFold(.archive)))
        #expect(row.isCollapsed)
        #expect(row.childCount == 6, "b, g2, h1, h2, k1, k2")
        #expect(row.group == nil)
    }

    @Test func openedItListsArchivedRowsInDocumentOrderThenArchivedMembersOfLiveGroups() {
        #expect(Self.keys(Self.options(open: true)) == [
            Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), .doneFold(.archive),
            Self.w("b"), Self.g("h"), Self.w("h1"), Self.w("h2"), Self.g("k"), Self.w("k1"), Self.w("k2"), Self.w("g2"),
        ])
    }

    @Test func theArchiveRowSitsBelowEveryOtherRow() throws {
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        let archive = try #require(layout.row(for: .doneFold(.archive)))
        #expect(layout.rows.allSatisfy { $0.key == .doneFold(.archive) || $0.y < archive.y })
    }

    @Test func theActiveArchivedWorkspaceStaysInItsPlace() throws {
        let keys = Self.keys(Self.options(active: "g2"))
        #expect(Array(keys.prefix(5)) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), Self.w("g2")])
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options(active: "g2"))
        #expect(try #require(layout.row(for: .doneFold(.archive))).childCount == 5)
    }

    @Test func aFilterListsArchivedMatchesInPlace() {
        var o = Self.options()
        o.filterMatches = [WorkspaceID("b"), WorkspaceID("h1")]
        let keys = Self.keys(o)
        #expect(keys.contains(Self.w("b")) && keys.contains(Self.w("h1")))
        #expect(!keys.contains(.doneFold(.archive)))
    }

    @Test func offDrawsTheOldPerListRows() {
        var o = Self.options()
        o.archiveSection = false
        let keys = Self.keys(o)
        #expect(!keys.contains(.doneFold(.archive)))
        #expect(keys.contains(Self.g("h")) && keys.contains(Self.g("k")))
    }

    @Test func nothingArchivedDrawsNoArchiveRow() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), Self.group("g", [Self.ws("g1")])])]
        #expect(!Self.keys(Self.options(), sections).contains(.doneFold(.archive)))
    }

    /// Two computers, each with archived rows: one Archive row, and every row key appears once (no second machine
    /// header, no duplicated Done row) with the archive open.
    @Test func twoComputersShareOneArchiveAndNoKeyRepeats() {
        let sections = [
            SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), .workspace(Self.ws("b", archived: true))]),
            SidebarSection(kind: .machine(Self.builder), nodes: [.workspace(Self.ws("x")), .workspace(Self.ws("y", archived: true))]),
        ]
        let keys = SidebarLayout.make(sections: sections, metrics: .standard, options: Self.options(open: true)).rows.map(\.key)
        #expect(Set(keys).count == keys.count, "\(keys)")
        #expect(keys.filter { $0 == .doneFold(.archive) }.count == 1)
        #expect(keys.suffix(2) == [Self.w("b"), Self.w("y")])
    }

    /// The row reads "Archive (N)" behind a disclosure chevron and opens through the fold's shared action.
    @Test func theRowReadsArchiveWithAChevron() throws {
        _ = NSApplication.shared
        let row = SidebarDoneFoldRowView(key: .doneFold(.archive))
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        row.configure(try #require(layout.row(for: .doneFold(.archive))))
        #expect(row.accessibilityLabel() == Strings.archiveSection(6))
        #expect(Strings.archiveSection(6).contains("6"))
        #expect(row.accessibilityRole() == .disclosureTriangle)
        #expect(row.showsChevron)
    }
}
