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
            #expect(order.step(from: .workspace(WorkspaceID("work-2")), by: 1, Self.numbers) == .workspace(WorkspaceID("work-3")))
            #expect(order.step(from: .workspace(WorkspaceID("work-2")), by: -1, Self.numbers) == .workspace(WorkspaceID("work-1")))
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
}
