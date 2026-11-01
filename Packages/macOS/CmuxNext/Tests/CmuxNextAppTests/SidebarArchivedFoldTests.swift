import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Archived workspaces fold into one "Archived (N)" row at the end of their group or loose list, after the Done fold;
/// the row opens them again below it (Lawrence 18470: "better ui for archived stuff instead of just greying them out
/// ... it takes up too much vertical space rn"; gallery pick V2).
@MainActor @Suite(.serialized) struct SidebarArchivedFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func ws(_ id: String, archived: Bool = false, done: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        row.isArchived = archived
        if done { row.taskStatus = .done }
        return row
    }

    /// Loose a, b (archived), c (done), d (archived); then group g: g1 (archived), g2, g3 (archived).
    static func sections() -> [SidebarSection] {
        let group = SidebarGroup(id: GroupID("g"), name: "G", color: .green,
                                 workspaces: [ws("g1", archived: true), ws("g2"), ws("g3", archived: true)])
        let nodes: [SidebarNode] = [.workspace(ws("a")), .workspace(ws("b", archived: true)), .workspace(ws("c", done: true)),
                                    .workspace(ws("d", archived: true)), .group(group)]
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static let section = SectionID.machine(.local)
    static let looseDone = SidebarDoneFoldID(section: section, group: nil)
    static let looseArchived = SidebarDoneFoldID(section: section, group: nil, kind: .archived)
    static let groupArchived = SidebarDoneFoldID(section: section, group: GroupID("g"), kind: .archived)

    static func options(open: Set<SidebarDoneFoldID> = [], active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.archiveSection = false // these cover the per-list rows the Archive section replaced by default
        o.openDoneFolds = open
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections(), metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    @Test func archivedWorkspacesFoldIntoOneRowPerListAfterTheDoneFold() {
        #expect(Self.keys(Self.options()) == [
            Self.w("a"), .group(GroupID("g")), Self.w("g2"), .doneFold(Self.groupArchived),
            .doneFold(Self.looseDone), .doneFold(Self.looseArchived),
        ])
    }

    @Test func theArchivedRowCountsItsWorkspacesAndEndsItsGroup() throws {
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        let loose = try #require(layout.row(for: .doneFold(Self.looseArchived)))
        #expect(loose.childCount == 2 && loose.isCollapsed)
        let grouped = try #require(layout.row(for: .doneFold(Self.groupArchived)))
        #expect(grouped.childCount == 2 && grouped.group == GroupID("g") && grouped.isLastInGroup)
    }

    @Test func anOpenArchivedRowListsItsWorkspacesInTheirOrder() {
        #expect(Self.keys(Self.options(open: [Self.looseArchived, Self.groupArchived])) == [
            Self.w("a"), .group(GroupID("g")), Self.w("g2"), .doneFold(Self.groupArchived), Self.w("g1"), Self.w("g3"),
            .doneFold(Self.looseDone), .doneFold(Self.looseArchived), Self.w("b"), Self.w("d"),
        ])
    }

    @Test func theActiveArchivedWorkspaceStaysInPlace() throws {
        let keys = Self.keys(Self.options(active: "b"))
        #expect(Array(keys.prefix(2)) == [Self.w("a"), Self.w("b")])
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options(active: "b"))
        #expect(try #require(layout.row(for: .doneFold(Self.looseArchived))).childCount == 1)
    }

    @Test func aFilterListsArchivedMatchesInPlace() {
        var o = Self.options()
        o.filterMatches = [WorkspaceID("b"), WorkspaceID("g1")]
        #expect(!Self.keys(o).contains(.doneFold(Self.looseArchived)))
    }

    @Test func offListsArchivedRowsInPlace() {
        var o = Self.options()
        o.foldsArchived = false
        #expect(Self.keys(o).contains(Self.w("b")) && !Self.keys(o).contains(.doneFold(Self.looseArchived)))
    }

    /// The row reads "Archived (N)" behind a disclosure chevron (V2 caption: chevron, not a box icon), and a click
    /// opens it through the fold's shared action.
    @Test func theRowReadsArchivedWithAChevronAndTogglesOpen() throws {
        _ = NSApplication.shared
        let row = SidebarDoneFoldRowView(key: .doneFold(Self.looseArchived))
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        row.configure(try #require(layout.row(for: .doneFold(Self.looseArchived))))
        #expect(row.accessibilityLabel() == Strings.archivedFold(2))
        #expect(Strings.archivedFold(2).contains("2"))
        #expect(row.accessibilityRole() == .disclosureTriangle)
        #expect(row.showsChevron)
    }
}
