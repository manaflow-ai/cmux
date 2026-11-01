import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Lawrence 2026-10-20: "hovering on workspace group or tab group for a while should still show the
/// card, like summary stuff, and should be fully customizable too." Resting on a sidebar group's
/// header for the group delay opens the shared group summary card; a shorter rest (a sweep) opens
/// none, and `sidebar.hoverCards.groups.workspaceGroups` off opens none at all.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupHoverCardTests {
    private static let groupID = GroupID("grp-agents")

    private static func sidebar(clock: ManualClock) -> (SidebarListView, NSWindow, HoverCardCoordinator, SidebarRow) {
        var working = SidebarWorkspace(id: WorkspaceID("ws-1"), title: "api", branch: "main", activity: .working)
        working.ports = ":3000"
        let members = [working,
                       SidebarWorkspace(id: WorkspaceID("ws-2"), title: "web", branch: "feat-ui", unread: .count(2)),
                       SidebarWorkspace(id: WorkspaceID("ws-3"), title: "docs")]
        let group = SidebarGroup(id: groupID, name: "Agents & routing", workspaces: members)
        return sidebar(clock: clock, nodes: [.group(group)], header: groupID)
    }

    private static func sidebar(clock: ManualClock, nodes: [SidebarNode],
                                header id: GroupID) -> (SidebarListView, NSWindow, HoverCardCoordinator, SidebarRow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let header = list.displayed.rows.first { $0.key == .group(id) }!
        return (list, window, coordinator, header)
    }

    private static func rest(_ list: SidebarListView, on row: SidebarRow) {
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil))
    }

    private static func settle(until done: @escaping () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func tearDown(_ list: SidebarListView, _ window: NSWindow, _ coordinator: HoverCardCoordinator) {
        coordinator.dismiss(.action)
        window.contentView = nil
        window.close()
    }

    @Test func restingOnAGroupHeaderShowsItsSummaryCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        Self.rest(list, on: header)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.groupHoverCard.delay + .milliseconds(50))
        try await Self.settle { coordinator.machine.shownTarget != nil }
        let shown = try #require(coordinator.machine.shownTarget, "resting on the group header showed no card")
        #expect(shown.id == WorkspaceHoverCardController.targetID(Self.groupID))
        #expect(list.hoverCard.shownGroupID == Self.groupID)
        let body = try #require(list.hoverCard.hoverCardBody(for: shown.id)?.view as? GroupHoverCardView)
        #expect(body.lines.first == "Agents & routing")
        #expect(body.lines.contains("Working: 1 \u{00B7} Unread: 2"), "\(body.lines)")
        #expect(body.lines.contains("Workspaces: 3"), "\(body.lines)")
        #expect(body.lines.contains("Branches: main, feat-ui"), "\(body.lines)")
        #expect(body.lines.contains("Ports: :3000"), "\(body.lines)")
    }

    /// One card (a361, 2026-10-20): a group's card is the coordinator's one card window, the same
    /// one `presentOwned` shows the update highlights in. An owned card morphs the group card into
    /// itself in that window; no second window opens.
    @Test func aGroupCardSharesTheOneCardWindowWithOwnedCards() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        Self.rest(list, on: header)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.groupHoverCard.delay + .milliseconds(50))
        try await Self.settle { coordinator.machine.shownTarget != nil }
        let groupTarget = WorkspaceHoverCardController.targetID(Self.groupID)
        #expect(coordinator.isShowing(groupTarget))
        let cardWindow = try #require(coordinator.cardWindow)

        let owned = HoverTargetID("test:owned")
        let body = HoverCardBody(view: NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40)), placement: .beside,
                                 themeAnchor: list, applyTheme: {})
        coordinator.presentOwned(owned, body: body, anchor: try #require(list.hoverCardAnchor(forGroup: Self.groupID)),
                                 parent: window, interactive: false) {}
        #expect(coordinator.cardWindow === cardWindow, "the owned card opened a second window")
        #expect(coordinator.isShowingOwned(owned))
        #expect(!coordinator.isShowing(groupTarget), "the group card and the owned card both show")
        coordinator.endOwned(owned)
    }

    /// "For a while": a group waits its own delay, longer than a row's, so a rest that would open a
    /// workspace card opens no group card yet.
    @Test func aGroupWaitsLongerThanARow() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(DesignSettings.shared.groupHoverCard.delay > DesignSettings.shared.hoverCardDelay)
        Self.rest(list, on: header)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(10))
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.machine.shownTarget == nil)
    }

    @Test func turningGroupCardsOffShowsNone() async throws {
        let saved = DesignSettings.shared.groupHoverCard
        DesignSettings.shared.groupHoverCard.workspaceGroups = false
        defer { DesignSettings.shared.groupHoverCard = saved }
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        let point = NSPoint(x: list.bounds.midX, y: (header.y + header.maxY) / 2)
        #expect(list.hoverCardGroup(at: point) == nil)
        Self.rest(list, on: header)
        clock.advance(by: .milliseconds(5_000))
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.machine.shownTarget == nil)
    }
    private static func nested(_ id: GroupID, name: String, parent: GroupID? = nil, depth: Int = 0,
                               _ members: [SidebarWorkspace] = []) -> SidebarNode {
        var made = SidebarGroup(id: id, name: name, workspaces: members)
        made.parent = parent
        made.depth = depth
        return .group(made)
    }

    /// Leo 2026-10-20: "cmux-next app · All idle · Workspaces: 0" over a group that holds workspaces. A
    /// group's subgroups follow it in the section, so the card counted only the group's own rows: a
    /// parent whose workspaces sit in subgroups read empty and idle.
    @Test func aParentGroupsCardCountsTheWorkspacesInItsSubgroups() async throws {
        let app = GroupID("grp-app"), branch = GroupID("grp-branch"), leaf = GroupID("grp-leaf")
        let nodes = [
            Self.nested(app, name: "cmux-next app"),
            Self.nested(branch, name: "sidebar", parent: app, depth: 1,
                        [SidebarWorkspace(id: WorkspaceID("ws-a"), title: "a", activity: .working)]),
            Self.nested(leaf, name: "rows", parent: branch, depth: 2,
                        [SidebarWorkspace(id: WorkspaceID("ws-b"), title: "b", unread: .count(1)),
                         SidebarWorkspace(id: WorkspaceID("ws-c"), title: "c")]),
        ]
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock, nodes: nodes, header: app)
        defer { Self.tearDown(list, window, coordinator) }
        Self.rest(list, on: header)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.groupHoverCard.delay + .milliseconds(50))
        try await Self.settle { coordinator.machine.shownTarget != nil }
        let shown = try #require(coordinator.machine.shownTarget, "resting on the parent group showed no card")
        let body = try #require(list.hoverCard.hoverCardBody(for: shown.id)?.view as? GroupHoverCardView)
        #expect(body.lines.contains("Workspaces: 3"), "\(body.lines)")
        #expect(body.lines.contains("Working: 1 \u{00B7} Unread: 1"), "\(body.lines)")
    }

    /// A group with nothing in it, nor in any subgroup, has nothing to summarize: no card opens.
    @Test func anEmptyGroupShowsNoCard() async throws {
        let empty = GroupID("grp-empty")
        let nodes = [Self.nested(empty, name: "Later"),
                     Self.nested(GroupID("grp-sub"), name: "inner", parent: empty, depth: 1)]
        let clock = ManualClock()
        let (list, window, coordinator, header) = Self.sidebar(clock: clock, nodes: nodes, header: empty)
        defer { Self.tearDown(list, window, coordinator) }
        let point = NSPoint(x: list.bounds.midX, y: (header.y + header.maxY) / 2)
        #expect(list.hoverCardGroup(at: point) == nil, "an empty group offers a card")
    }
}
