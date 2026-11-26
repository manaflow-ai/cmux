import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// cmux#51635: archived workspaces, archived links and every group whose workspaces are all archived (or that is archived
/// itself) leave the sidebar. No "Archive (N)" row, no "Archived (N)" fold: Settings > Sidebar > Archived Workspaces
/// lists them (`SidebarArchivedList`), as ChatGPT keeps archived chats in Settings > Data controls > Archived chats.
/// Before, they folded under an "Archive (N)" row at the bottom of the sidebar that listed them dimmed when opened.
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

    static func options(active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions, _ sections: [SidebarSection] = sections()) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }
    static func g(_ id: String) -> SidebarRowKey { .group(GroupID(id)) }

    static func isFold(_ key: SidebarRowKey) -> Bool { if case .doneFold = key { true } else { false } }

    /// The issue's screenshot: live rows only, and nothing below them.
    @Test func archivedRowsLeaveTheSidebarWithNoRowOfTheirOwn() {
        #expect(Self.keys(Self.options()) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1")])
    }

    @Test func noFoldRowStandsForThem() {
        #expect(!Self.keys(Self.options()).contains(where: Self.isFold))
    }

    @Test func anArchivedLinkLeavesToo() {
        var link = SidebarListItem(id: "old-link", ref: .url("https://example.com"), title: "Example")
        link.isArchived = true
        let live = SidebarListItem(id: "live-link", ref: .url("https://example.org"), title: "Live")
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), .item(live), .item(link)])]
        let keys = Self.keys(Self.options(), sections)
        #expect(keys.contains(.item("live-link")))
        #expect(!keys.contains(.item("old-link")))
    }

    /// Open from Settings shows the workspace: the active one keeps its place, dimmed, and its group stays.
    @Test func theActiveArchivedWorkspaceStaysInItsPlace() {
        #expect(Self.keys(Self.options(active: "g2")) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), Self.w("g2")])
        #expect(Self.keys(Self.options(active: "b")) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), Self.w("b")])
        #expect(Self.keys(Self.options(active: "h1")) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1"), Self.g("h"), Self.w("h1")])
    }

    @Test func aFilterListsArchivedMatchesInPlace() {
        var o = Self.options()
        o.filterMatches = [WorkspaceID("b"), WorkspaceID("h1")]
        let keys = Self.keys(o)
        #expect(keys.contains(Self.w("b")) && keys.contains(Self.w("h1")))
        #expect(!keys.contains(where: Self.isFold))
    }

    /// Group by Status used to draw archived rows in place; they leave there too.
    @Test func groupByStatusLeavesThemOut() {
        var o = Self.options()
        o.grouping.setByStatus(true)
        let keys = Self.keys(o)
        for id in ["b", "g2", "h1", "h2", "k1", "k2"] { #expect(!keys.contains(Self.w(id)), "\(id)") }
        #expect(keys.contains(Self.w("a")))
    }

    /// A drag unfolds Done rows; it never draws archived rows back.
    @Test func aDragNeverDrawsThemBack() {
        var o = Self.options()
        o.unfoldsAll()
        let keys = Self.keys(o)
        #expect(!keys.contains(Self.w("b")) && !keys.contains(Self.g("h")) && !keys.contains(Self.w("g2")))
    }

    @Test func offDrawsTheOldPerListRows() {
        var o = Self.options()
        o.archiveSection = false
        let keys = Self.keys(o)
        #expect(keys.contains(Self.g("h")) && keys.contains(Self.g("k")))
    }

    /// Lineage nesting is on by default (#28103), so the session tree is set for everyone: a row whose parent was
    /// archived draws as a root of its list.
    @Test func theSessionTreeLeavesThemOutToo() {
        var o = Self.options()
        o.sessionTree = SidebarSessionTreeState()
        #expect(Self.keys(o) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1")])
        o.sessionTree = SidebarSessionTreeState(parents: [WorkspaceID("c"): WorkspaceID("b"), WorkspaceID("g1"): WorkspaceID("g2")])
        #expect(Self.keys(o) == [Self.w("a"), Self.w("c"), Self.g("g"), Self.w("g1")])
    }

    @Test func twoComputersLeaveThemOutAndNoKeyRepeats() {
        let sections = [
            SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), .workspace(Self.ws("b", archived: true))]),
            SidebarSection(kind: .machine(Self.builder), nodes: [.workspace(Self.ws("x")), .workspace(Self.ws("y", archived: true))]),
        ]
        let keys = SidebarLayout.make(sections: sections, metrics: .standard, options: Self.options()).rows.map(\.key)
        #expect(Set(keys).count == keys.count, "\(keys)")
        #expect(!keys.contains(Self.w("b")) && !keys.contains(Self.w("y")))
        #expect(keys.contains(Self.w("a")) && keys.contains(Self.w("x")))
    }

    // MARK: Nested groups and group links (review of cmux#51635)

    static func nested(_ id: String, parent: String? = nil, _ members: [SidebarWorkspace], items: [SidebarListItem] = [],
                       archived: Bool = false) -> SidebarNode {
        var group = SidebarGroup(id: GroupID(id), name: id.uppercased(), color: .green, workspaces: members)
        group.parent = parent.map(GroupID.init)
        group.depth = parent == nil ? 0 : 1
        group.items = items.map { SidebarGroupItem(item: $0) }
        group.isArchived = archived
        return .group(group)
    }

    static func link(_ id: String, archived: Bool = false) -> SidebarListItem {
        var link = SidebarListItem(id: id, ref: .url("https://example.com/\(id)"), title: id)
        link.isArchived = archived
        return link
    }

    /// Group a's own workspace is archived but its subgroup b holds a live one: the reducer leaves a live, so the
    /// sidebar keeps a and b, and w2 is never lost (it is in neither the sidebar nor Settings otherwise).
    @Test func aGroupWithALiveSubgroupStays() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            Self.nested("a", [Self.ws("w1", archived: true)]),
            Self.nested("b", parent: "a", [Self.ws("w2")]),
        ])]
        let keys = Self.keys(Self.options(), sections)
        #expect(keys.contains(Self.g("a")) && keys.contains(Self.g("b")) && keys.contains(Self.w("w2")))
        #expect(!keys.contains(Self.w("w1")))
        #expect(SidebarArchivedList.entries(in: sections).map(\.id) == ["w1"])
    }

    /// A group whose workspaces are all archived but that holds a live link stays, with the link.
    @Test func aGroupWithALiveLinkStays() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            Self.nested("a", [Self.ws("w1", archived: true)], items: [Self.link("live")]),
        ])]
        let keys = Self.keys(Self.options(), sections)
        #expect(keys.contains(Self.g("a")) && keys.contains(.item("live")))
        #expect(!keys.contains(Self.w("w1")))
    }

    /// An archived link inside a live group leaves the sidebar and is listed in Settings with its group.
    @Test func anArchivedLinkInAGroupLeavesAndIsListed() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            Self.nested("a", [Self.ws("w1")], items: [Self.link("old", archived: true), Self.link("live")]),
        ])]
        let keys = Self.keys(Self.options(), sections)
        #expect(keys.contains(.item("live")) && !keys.contains(.item("old")))
        let entries = SidebarArchivedList.entries(in: sections)
        #expect(entries.map(\.id) == ["old"] && entries.first?.kind == .item && entries.first?.group == "A")
    }

    /// A wholly archived group with a subgroup and links leaves with all of them, and Settings lists every row.
    @Test func aWhollyArchivedTreeLeavesAndIsListed() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            .workspace(Self.ws("x")),
            Self.nested("a", [Self.ws("w1", archived: true)], items: [Self.link("l1", archived: true)], archived: true),
            Self.nested("b", parent: "a", [Self.ws("w2", archived: true)]),
        ])]
        #expect(Self.keys(Self.options(), sections) == [Self.w("x")])
        #expect(Set(SidebarArchivedList.entries(in: sections).map(\.id)) == ["w1", "l1", "w2"])
    }

    /// Open from Settings on a workspace in subgroup b of archived group a draws a and b above it, never b alone.
    @Test func theActiveRowKeepsEveryGroupAboveIt() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [
            Self.nested("a", [Self.ws("w1", archived: true)], archived: true),
            Self.nested("b", parent: "a", [Self.ws("w2", archived: true), Self.ws("w3", archived: true)]),
        ])]
        #expect(Self.keys(Self.options(active: "w2"), sections) == [Self.g("a"), Self.g("b"), Self.w("w2")])
    }

    // MARK: Settings > Sidebar > Archived Workspaces

    /// The list holds every archived workspace in sidebar order (members of archived groups too, each once), with
    /// its group and computer, then archived links: what the sidebar left out.
    @Test func theSettingsListHoldsEveryArchivedRowInSidebarOrder() {
        let entries = SidebarArchivedList.entries(in: Self.sections())
        #expect(entries.map(\.id) == ["g2", "b", "h1", "h2", "k1", "k2"])
        #expect(entries.allSatisfy { $0.kind == .workspace && $0.machine == "This Mac" })
        #expect(entries.first { $0.id == "g2" }?.group == "G")
        #expect(entries.first { $0.id == "b" }?.group == nil)
    }

    @Test func theSettingsListHoldsArchivedLinksAndSkipsPinned() {
        var link = SidebarListItem(id: "old-link", ref: .url("https://example.com"), title: "Example")
        link.isArchived = true
        let pinned = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarDocStore.pinnedSection)),
                                    nodes: [.workspace(Self.ws("p", archived: true))])
        let local = SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), .item(link)])
        let entries = SidebarArchivedList.entries(in: [pinned, local])
        #expect(entries == [SidebarArchivedEntry(kind: .item, id: "old-link", title: "Example")])
    }

    @Test func aWorkspaceTwoComputersListIsListedOnce() {
        let sections = [
            SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("b", archived: true))]),
            SidebarSection(kind: .machine(Self.builder), nodes: [.workspace(Self.ws("b", archived: true))]),
        ]
        #expect(SidebarArchivedList.entries(in: sections).map(\.id) == ["b"])
    }

    @Test func nothingArchivedListsNothing() {
        let sections = [SidebarSection(kind: .machine(Self.local), nodes: [.workspace(Self.ws("a")), Self.group("g", [Self.ws("g1")])])]
        #expect(SidebarArchivedList.entries(in: sections).isEmpty)
        #expect(Self.keys(Self.options(), sections) == [Self.w("a"), Self.g("g"), Self.w("g1")])
    }
}
