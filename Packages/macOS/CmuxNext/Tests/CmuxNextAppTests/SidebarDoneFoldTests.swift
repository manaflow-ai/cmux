import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Workspaces marked Done (Mark as Done, `SidebarTaskStatus.done`) fold into one "Done (N)" row at the end of their
/// group or list, in their manual order; the row opens them again below it (Leo's sidebar organization, slice S4).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDoneFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func ws(_ id: String, done: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        if done { row.taskStatus = .done }
        return row
    }

    /// Loose a, b (done), c, d (done); then group g: g1 (done), g2, g3 (done).
    static func sections(collapsed: Bool = false) -> [SidebarSection] {
        var group = SidebarGroup(id: GroupID("g"), name: "G", color: .green,
                                 workspaces: [ws("g1", done: true), ws("g2"), ws("g3", done: true)])
        group.isCollapsed = collapsed
        let nodes: [SidebarNode] = [.workspace(ws("a")), .workspace(ws("b", done: true)), .workspace(ws("c")),
                                    .workspace(ws("d", done: true)), .group(group)]
        return [SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static let section = SectionID.machine(.local)
    static let looseFold = SidebarDoneFoldID(section: section, group: nil)
    static let groupFold = SidebarDoneFoldID(section: section, group: GroupID("g"))

    static func options(open: Set<SidebarDoneFoldID> = [], active: String? = nil) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.openDoneFolds = open
        o.activeWorkspaceID = active.map(WorkspaceID.init)
        return o
    }

    static func keys(_ o: SidebarLayoutOptions, _ sections: [SidebarSection] = sections()) -> [SidebarRowKey] {
        SidebarLayout.make(sections: sections, metrics: .standard, options: o).rows.map(\.key)
            .filter { if case .section = $0 { false } else { true } }
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID(id)) }

    @Test func doneWorkspacesFoldIntoOneRowAtTheEnd() {
        #expect(Self.keys(Self.options()) == [
            Self.w("a"), Self.w("c"), .group(GroupID("g")), Self.w("g2"), .doneFold(Self.groupFold), .doneFold(Self.looseFold),
        ])
    }

    @Test func theFoldRowCountsItsWorkspaces() throws {
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: Self.options())
        let loose = try #require(layout.row(for: .doneFold(Self.looseFold)))
        #expect(loose.childCount == 2)
        #expect(loose.isCollapsed)
        let grouped = try #require(layout.row(for: .doneFold(Self.groupFold)))
        #expect(grouped.childCount == 2)
        #expect(grouped.group == GroupID("g"))
        #expect(grouped.isLastInGroup)
    }

    @Test func anOpenFoldListsItsWorkspacesInTheirOrder() {
        #expect(Self.keys(Self.options(open: [Self.looseFold, Self.groupFold])) == [
            Self.w("a"), Self.w("c"), .group(GroupID("g")), Self.w("g2"), .doneFold(Self.groupFold), Self.w("g1"), Self.w("g3"),
            .doneFold(Self.looseFold), Self.w("b"), Self.w("d"),
        ])
    }

    @Test func theActiveWorkspaceStaysInPlace() {
        #expect(Self.keys(Self.options(active: "b")) == [
            Self.w("a"), Self.w("b"), Self.w("c"), .group(GroupID("g")), Self.w("g2"), .doneFold(Self.groupFold), .doneFold(Self.looseFold),
        ])
    }

    @Test func offListsEveryRowInPlace() {
        var o = Self.options()
        o.foldsDone = false
        #expect(Self.keys(o) == [
            Self.w("a"), Self.w("b"), Self.w("c"), Self.w("d"), .group(GroupID("g")), Self.w("g1"), Self.w("g2"), Self.w("g3"),
        ])
    }

    @Test func aFilterListsEveryMatch() {
        var o = Self.options()
        o.filterMatches = [WorkspaceID("b"), WorkspaceID("c")]
        #expect(Self.keys(o) == [Self.w("b"), Self.w("c")])
    }

    /// A group's fold is spliced from its members as they are; one holding Done workspaces is laid out again.
    @Test func aGroupWithDoneWorkspacesIsNotSpliced() throws {
        let o = Self.options()
        let shown = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        let sections = Self.sections(collapsed: true)
        guard case let .group(group) = sections[0].nodes[4] else { Issue.record("no group"); return }
        #expect(shown.folding(group, collapsed: true, in: sections[0], metrics: .standard, options: o) == nil)
    }

    /// Marking a workspace Done moves its row: the list lays out again instead of patching the row in place.
    @Test func markingDoneMovesTheRow() {
        let model = SidebarModel(sections: Self.sections())
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        #expect(!model.patchWorkspaces([Self.ws("a", done: true)]))
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(false))
        #expect(model.patchWorkspaces([Self.ws("c", done: true)]))
    }

    @Test func theRowSaysHowManyAreDone() {
        #expect(Strings.doneFold(3).contains("3"))
    }

    /// A Done workspace chosen from elsewhere (the palette, Cmd-number, the socket) shows in its place: the selection
    /// patch hands over to a layout instead of selecting a row the list does not draw.
    @Test func aDoneWorkspaceSelectedElsewhereShows() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        let model = SidebarModel(sections: Self.sections(), activeWorkspaceID: WorkspaceID("a"))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        try #require(list.displayed.row(for: .doneFold(Self.looseFold)) != nil, "the list draws no Done row")
        #expect(list.displayed.row(for: Self.w("b")) == nil)
        model.activeWorkspaceID = WorkspaceID("b")
        #expect(!list.patchSelection(from: .workspace(WorkspaceID("a")), oldSelection: []), "the patch selected a row the list does not draw")
        list.reload(animated: false)
        #expect(list.displayed.row(for: Self.w("b")) != nil)
    }
}
