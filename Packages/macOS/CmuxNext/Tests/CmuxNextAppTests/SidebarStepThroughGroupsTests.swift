import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 binds Next/Previous Sidebar Item (`nextSidebarTab` / `prevSidebarTab`) to ⌃⇥ / ⌃⇧⇥
/// and walks the whole sidebar with them. The walk visits every drawn row in order, the members of
/// an expanded group included, and a collapsed group is one stop (its members draw no row).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarStepThroughGroupsTests {
    private static func row(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    private static func model() -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(row("loose-1")),
                .group(SidebarGroup(id: GroupID("open"), name: "Open", color: .red, isCollapsed: false,
                                    workspaces: [row("open-1"), row("open-2")])),
                .group(SidebarGroup(id: GroupID("shut"), name: "Shut", color: .green, isCollapsed: true,
                                    workspaces: [row("shut-1"), row("shut-2")])),
                .workspace(row("loose-2")),
            ]),
        ])
    }

    private static let rowsOnly = SidebarNavigationSettings(stepping: .workspacesOnly)

    @Test func theWalkVisitsEveryDrawnRowInOrder() {
        let order = Self.model().itemOrder
        #expect(order.rows == [.workspace(WorkspaceID("loose-1")), .workspace(WorkspaceID("open-1")), .workspace(WorkspaceID("open-2")),
                               .group(GroupID("shut")), .workspace(WorkspaceID("loose-2"))])
    }

    @Test func nextAndPreviousStepIntoAndOutOfAnExpandedGroup() {
        let order = Self.model().itemOrder
        #expect(order.step(from: .workspace(WorkspaceID("loose-1")), by: 1, Self.rowsOnly) == .workspace(WorkspaceID("open-1")))
        #expect(order.step(from: .workspace(WorkspaceID("open-2")), by: 1, Self.rowsOnly) == .group(GroupID("shut")))
        #expect(order.step(from: .workspace(WorkspaceID("open-1")), by: -1, Self.rowsOnly) == .workspace(WorkspaceID("loose-1")))
    }

    @Test func aCollapsedGroupIsOneStopAndItsMembersAreNot() {
        let order = Self.model().itemOrder
        // Shown from the collapsed group (its first member is the window's workspace), the walk goes on past it.
        #expect(order.step(from: .workspace(WorkspaceID("shut-1")), by: 1, Self.rowsOnly) == .workspace(WorkspaceID("loose-2")))
        #expect(order.step(from: .workspace(WorkspaceID("shut-2")), by: -1, Self.rowsOnly) == .workspace(WorkspaceID("open-2")))
        #expect(!order.rows.contains(.workspace(WorkspaceID("shut-1"))))
    }

    // Leo 2026-11-07: "when I command 1 2 3 4 5 6 7 ... around an area that has a group at the, like, immediate top
    // or bottom, it messes things up." The numbers count the rows the sidebar draws: a member folded into its group's
    // "Done (N)" row, or hidden behind "Show N more", is no stop, and the numbers never depend on the selection.

    private static func done(_ id: String) -> SidebarWorkspace {
        var ws = row(id)
        ws.taskStatus = .done
        return ws
    }

    private static let work = GroupID("work")

    private static func doneSections(_ members: [SidebarWorkspace]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(row("top")),
            .group(SidebarGroup(id: work, name: "Work", color: .red, isCollapsed: false, workspaces: members)),
            .workspace(row("below")),
        ])]
    }

    private static let withDone = [row("work-1"), done("work-2"), row("work-3")]
    private static let numbers = SidebarNavigationSettings(numbering: .workspacesOnly, stepping: .workspacesOnly)

    private static func ids(_ names: [String]) -> [SidebarItem] { names.map { .workspace(WorkspaceID($0)) } }

    /// Runs `body` with `sidebar.groupRowLimit` at `limit` (Done folds are always on), then restores it.
    private static func withFolds(limit: Double = 0, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all) // an unregistered tunable keeps its default
        TunableStore.shared.set(SidebarTunables.groupRowLimit.key, .number(limit))
        defer {
            TunableStore.shared.set(SidebarTunables.groupRowLimit.key, nil)
        }
        try body()
    }

    @Test func aDoneMemberFoldedIntoItsGroupIsNoNumberStop() {
        Self.withFolds {
            let order = SidebarModel(sections: Self.doneSections(Self.withDone)).itemOrder
            #expect(order.rows == Self.ids(["top", "work-1", "work-3", "below"]))
            #expect(order.pick(3, Self.numbers) == .workspace(WorkspaceID("work-3")))
            #expect(order.pick(4, Self.numbers) == .workspace(WorkspaceID("below")))
        }
    }

    @Test func selectingTheDoneMemberChangesNoNumberAndStepsFromItsPlace() {
        Self.withFolds {
            let shown = SidebarModel(sections: Self.doneSections(Self.withDone), activeWorkspaceID: WorkspaceID("work-2"))
            let order = shown.itemOrder
            #expect(order.rows == SidebarModel(sections: Self.doneSections(Self.withDone)).itemOrder.rows)
            #expect(order.stop(for: .workspace(WorkspaceID("work-2"))) == nil, "the folded Done member is a number stop")
            // The selected Done member draws in its place: the walk goes on from there.
            #expect(shown.step(from: .workspace(WorkspaceID("work-2")), by: 1, Self.numbers) == .workspace(WorkspaceID("work-3")))
            #expect(shown.step(from: .workspace(WorkspaceID("work-2")), by: -1, Self.numbers) == .workspace(WorkspaceID("work-1")))
        }
    }

    @Test func anOpenedDoneFoldNumbersItsMembersWhereTheyDraw() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        try Self.withFolds {
            let model = SidebarModel(sections: Self.doneSections(Self.withDone))
            let sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 400), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            let fold = SidebarRowKey.doneFold(SidebarDoneFoldID(section: try #require(model.sections.first?.id), group: Self.work))
            try #require(sidebar.list.displayed.row(for: fold) != nil, "no Done row: \(sidebar.list.displayed.rows.map(\.key))")
            #expect(SidebarFoldAction(list: sidebar.list).toggle(fold))
            #expect(model.itemOrder.rows == Self.ids(["top", "work-1", "work-3", "work-2", "below"]))
        }
    }

    @Test func rowsBehindShowMoreAreNoNumberStops() {
        Self.withFolds(limit: 2) {
            let members = (1...4).map { Self.row("work-\($0)") }
            let order = SidebarModel(sections: Self.doneSections(members)).itemOrder
            #expect(order.rows == Self.ids(["top", "work-1", "work-2", "below"]))
        }
    }

    // Review follow-ups on #39747: a selected row draws in its place, so a step goes on from there.

    /// An opened Done fold lists its member at the end of the group, and it is a stop there: Next and Previous walk
    /// the stops in number order from it too, so repeated presses visit every row once and never come back.
    @Test func anOpenedDoneFoldsRowStepsInNumberOrder() throws {
        try Self.withFolds {
            let model = SidebarModel(sections: Self.doneSections(Self.withDone))
            let section = try #require(model.sections.first?.id)
            model.openDoneFolds = [SidebarDoneFoldID(section: section, group: Self.work)]
            let order = model.itemOrder
            #expect(order.rows == Self.ids(["top", "work-1", "work-3", "work-2", "below"]))
            let selected = SidebarItem.workspace(WorkspaceID("work-2"))
            #expect(order.number(for: selected, Self.numbers) == 4)
            #expect(model.step(from: selected, by: 1, Self.numbers) == .workspace(WorkspaceID("below")))
            #expect(model.step(from: selected, by: -1, Self.numbers) == .workspace(WorkspaceID("work-3")))
            var visited: [SidebarItem] = []
            var at: SidebarItem? = .workspace(WorkspaceID("top"))
            for _ in 0..<4 {
                at = model.step(from: at, by: 1, Self.numbers)
                if let at { visited.append(at) }
            }
            #expect(visited == Self.ids(["work-1", "work-3", "work-2", "below"]))
        }
    }

    /// A link between a workspace and a folded Done member is a stop of its own: from the selected Done member,
    /// Previous is the link and Next the workspace after it.
    @Test func aFoldedRowAfterALinkStepsPastTheLink() {
        Self.withFolds {
            let link = SidebarListItem(id: "link", ref: .url("https://example.com"), title: "Example")
            var group = SidebarGroup(id: Self.work, name: "Work", color: .red, isCollapsed: false, workspaces: Self.withDone)
            group.items = [SidebarGroupItem(item: link, after: WorkspaceID("work-1"))]
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
                .workspace(Self.row("top")), .group(group), .workspace(Self.row("below")),
            ])])
            let order = model.itemOrder
            let all = SidebarNavigationSettings(numbering: .allItems, stepping: .allItems)
            let linkItem = SidebarItem.topItem(LayoutItemID("link"))
            #expect(order.rows == [.workspace(WorkspaceID("top")), .workspace(WorkspaceID("work-1")), linkItem,
                                   .workspace(WorkspaceID("work-3")), .workspace(WorkspaceID("below"))])
            let selected = SidebarItem.workspace(WorkspaceID("work-2"))
            #expect(model.step(from: selected, by: -1, all) == linkItem)
            #expect(model.step(from: selected, by: 1, all) == .workspace(WorkspaceID("work-3")))
            #expect(model.step(from: selected, by: -1, Self.numbers) == .workspace(WorkspaceID("work-1")))
            #expect(model.step(from: selected, by: 1, Self.numbers) == .workspace(WorkspaceID("work-3")))
        }
    }

    /// An archived workspace sits in the closed Archive section at the bottom, but selected it draws in its place:
    /// Next and Previous are the rows around that place, not the ends of the list.
    @Test func aSelectedArchivedRowStepsFromItsPlace() {
        Self.withFolds {
            var archived = Self.row("old")
            archived.isArchived = true
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
                .workspace(Self.row("first")), .workspace(archived), .workspace(Self.row("second")), .workspace(Self.row("third")),
            ])])
            #expect(model.itemOrder.rows == Self.ids(["first", "second", "third"]))
            let selected = SidebarItem.workspace(WorkspaceID("old"))
            #expect(model.step(from: selected, by: 1, Self.numbers) == .workspace(WorkspaceID("second")))
            #expect(model.step(from: selected, by: -1, Self.numbers) == .workspace(WorkspaceID("first")))
        }
    }

    /// A filter folds nothing: Done rows draw in place as stops of their own, and a step from one goes to its
    /// neighbour (three Done rows in a row: Next from the middle one is the third).
    @Test func aFilterKeepsDoneRowsAsTheirOwnStops() {
        Self.withFolds {
            let members = [Self.done("work-1"), Self.done("work-2"), Self.done("work-3")]
            let model = SidebarModel(sections: Self.doneSections(members))
            model.filterText = "work"
            let order = model.itemOrder
            #expect(order.rows == Self.ids(["work-1", "work-2", "work-3"]))
            #expect(model.step(from: .workspace(WorkspaceID("work-2")), by: 1, Self.numbers) == .workspace(WorkspaceID("work-3")))
            #expect(model.step(from: .workspace(WorkspaceID("work-2")), by: -1, Self.numbers) == .workspace(WorkspaceID("work-1")))
        }
    }

    /// A row behind "Show N more" draws, selected, before an opened Done fold's rows at the end of its group: Previous
    /// is the row above it and Next the Done row below, not the other way round.
    @Test func aRowBehindShowMoreStepsBeforeAnOpenedDoneFold() throws {
        try Self.withFolds(limit: 1) {
            let members = [Self.row("work-1"), Self.done("work-2"), Self.row("work-3"), Self.row("work-4")]
            let model = SidebarModel(sections: Self.doneSections(members))
            let section = try #require(model.sections.first?.id)
            model.openDoneFolds = [SidebarDoneFoldID(section: section, group: Self.work)]
            #expect(!model.itemOrder.rows.contains(.workspace(WorkspaceID("work-3"))), "work-3 is behind Show more")
            let selected = SidebarItem.workspace(WorkspaceID("work-3"))
            #expect(model.step(from: selected, by: -1, Self.numbers) == .workspace(WorkspaceID("work-1")))
            #expect(model.step(from: selected, by: 1, Self.numbers) == .workspace(WorkspaceID("work-2")))
        }
    }

    /// An archived link the opened Archive lists at the bottom is no stop before a Done row above it: from the
    /// selected Done row, Previous and Next are the rows drawn around it.
    @Test func anArchivedItemIsNoAnchorForADoneRowAboveIt() {
        Self.withFolds {
            var link = SidebarListItem(id: "old-link", ref: .url("https://example.com"), title: "Example")
            link.isArchived = true
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
                .workspace(Self.row("first")), .item(link), .workspace(Self.done("finished")), .workspace(Self.row("second")),
            ])])
            model.openDoneFolds = [.archive]
            let all = SidebarNavigationSettings(numbering: .allItems, stepping: .allItems)
            let selected = SidebarItem.workspace(WorkspaceID("finished"))
            #expect(model.step(from: selected, by: -1, all) == .workspace(WorkspaceID("first")))
            #expect(model.step(from: selected, by: 1, all) == .workspace(WorkspaceID("second")))
        }
    }

    /// A Done member of a collapsed group steps from its group, the stop that stands for it: Previous is the row
    /// above the group, and pressing it again goes on up.
    @Test func aDoneMemberOfACollapsedGroupStepsFromItsGroup() {
        Self.withFolds {
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let shut = SidebarGroup(id: Self.work, name: "Work", color: .red, isCollapsed: true,
                                    workspaces: [Self.done("work-1"), Self.row("work-2")])
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
                .workspace(Self.row("top")), .group(shut), .workspace(Self.row("below")),
            ])])
            let selected = SidebarItem.workspace(WorkspaceID("work-1"))
            #expect(model.itemOrder.stop(for: selected) == .group(Self.work))
            #expect(model.step(from: selected, by: -1, Self.numbers) == .workspace(WorkspaceID("top")))
            #expect(model.step(from: selected, by: 1, Self.numbers) == .workspace(WorkspaceID("below")))
        }
    }
}
