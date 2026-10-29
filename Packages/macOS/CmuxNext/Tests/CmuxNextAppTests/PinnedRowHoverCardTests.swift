import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeupsTestSupport
import Testing

/// Lawrence 2026-10-28 ("pinned tabs not long enough? also they should reuse more code maybe so there is the
/// hover thing"; again: "pinned rows needs hover cards too"): resting on a pinned workspace row showed no card,
/// while a workspace row in the list shows the workspace hover card. A pinned row opens the same card, from the
/// list's one card controller: the same delay, the same contents, beside the pinned row.
@MainActor @Suite(.serialized) struct PinnedRowHoverCardTests {
    private static let pinnedID = WorkspaceID("ws-pinned")
    private static let listedID = WorkspaceID("ws-listed")
    private static let item = LayoutItem(id: LayoutItemID("itm_pin_card"), ref: .workspace("local:ws-pinned"))

    private static var pinned: SidebarWorkspace {
        var workspace = SidebarWorkspace(id: pinnedID, title: "Cloud Chief rebuild", directory: "~/fun/cmux", branch: "feat-cmux-next")
        workspace.workspaceDescription = "Durable runner for the cloud Chief"
        return workspace
    }

    private struct Harness {
        let list: SidebarListView
        let window: NSWindow
        let coordinator: HoverCardCoordinator

        /// The pinned row's view in its block.
        var pinnedRow: SidebarItemRowView? {
            list.blockRegions.lazy.compactMap { $0.itemViews[PinnedRowHoverCardTests.item.id] }.first
        }

        /// The middle of the pinned row, in the window.
        func pinnedRowMiddle() throws -> NSPoint {
            let row = try #require(pinnedRow, "the pinned workspace drew no row")
            return row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        }

        func tearDown() {
            coordinator.dismiss(.action)
            window.contentView = nil
            window.close()
        }
    }

    /// A list with a Pinned block holding one open workspace and a machine list holding another.
    private static func sidebar(clock: ManualClock) -> Harness {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let pinnedSection = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarDocStore.pinnedSection)), nodes: [])
        let listed = SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: listedID, title: "api", branch: "main"))])
        let model = SidebarModel(sections: [pinnedSection, listed], activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        var info = SidebarItemInfo(title: pinned.title, symbol: "textformat")
        info.textOnly = true
        info.workspace = pinnedID
        info.workspaceRow = pinned
        let section = SidebarLayoutDocument.pinnedSection(items: [item])
        list.blocks = SidebarListBlocks(sections: [section.id.rawValue: section], infos: [item.id: info], collapsed: [],
                                        look: .quiet, metrics: .standard, drawsLines: false, appHeights: [:])
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
        list.layoutSubtreeIfNeeded()
        return Harness(list: list, window: window, coordinator: coordinator)
    }

    private static func settle(until done: @escaping () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func restingOnAPinnedRowShowsItsWorkspaceCard() async throws {
        let clock = ManualClock()
        let harness = Self.sidebar(clock: clock)
        defer { harness.tearDown() }
        harness.list.updateHover(try harness.pinnedRowMiddle())
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(50))
        try await Self.settle { harness.coordinator.machine.shownTarget != nil }
        let shown = try #require(harness.coordinator.machine.shownTarget, "resting on a pinned row showed no card")
        #expect(shown.id == WorkspaceHoverCardController.targetID(Self.pinnedID))
        #expect(harness.list.hoverCard.shownID == Self.pinnedID)
        // The same card a list row of this workspace shows: the workspace card, with its name and facts.
        let body = try #require(harness.list.hoverCard.hoverCardBody(for: shown.id)?.view as? WorkspaceHoverCardView)
        let expected = WorkspaceHoverCardView()
        expected.configure(.make(Self.pinned, machine: nil, now: Date()))
        #expect(body.lines.first == expected.lines.first, "\(body.lines)")
        #expect(body.lines.contains { $0.contains("Durable runner for the cloud Chief") }, "\(body.lines)")
    }

    /// The same delay as a list row: no card before `sidebar.hoverCards.delay`.
    @Test func aPinnedRowWaitsARowsDelay() async throws {
        let clock = ManualClock()
        let harness = Self.sidebar(clock: clock)
        defer { harness.tearDown() }
        harness.list.updateHover(try harness.pinnedRowMiddle())
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay - .milliseconds(20))
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.coordinator.machine.shownTarget == nil, "a sweep over a pinned row opened a card early")
        clock.advance(by: .milliseconds(70))
        try await Self.settle { harness.coordinator.machine.shownTarget != nil }
        #expect(harness.coordinator.machine.shownTarget?.id == WorkspaceHoverCardController.targetID(Self.pinnedID))
    }

    /// The card goes beside the pinned row, its top on the row's top, as a list row's card does.
    @Test func aPinnedRowsCardAnchorsOnThatRow() throws {
        let harness = Self.sidebar(clock: ManualClock())
        defer { harness.tearDown() }
        let row = try #require(harness.pinnedRow)
        let onScreen = harness.window.convertToScreen(row.convert(row.bounds, to: nil))
        let anchor = try #require(harness.list.hoverCardAnchor(for: Self.pinnedID), "a pinned row has no card anchor")
        #expect(abs(anchor.minY - onScreen.minY) < 0.5 && abs(anchor.maxY - onScreen.maxY) < 0.5, "\(anchor) vs \(onScreen)")
        let band = try #require(harness.list.hoverCardBand(for: Self.pinnedID))
        #expect(abs(band.maxY - onScreen.maxY) < 0.5)
    }

    /// The list row of the other workspace still opens its own card (the pinned lookup takes nothing from it).
    @Test func aListRowStillShowsItsOwnCard() throws {
        let harness = Self.sidebar(clock: ManualClock())
        defer { harness.tearDown() }
        let row = try #require(harness.list.displayed.row(for: .workspace(Self.listedID)))
        let point = NSPoint(x: harness.list.bounds.midX, y: (row.y + row.maxY) / 2)
        #expect(harness.list.hoverCardWorkspace(at: point) == Self.listedID)
        let pinnedPoint = harness.list.convert(try harness.pinnedRowMiddle(), from: nil)
        #expect(harness.list.hoverCardWorkspace(at: pinnedPoint) == Self.pinnedID)
    }
}
