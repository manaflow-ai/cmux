import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-11-06: "when you're moving your cursor around the sort of highlighted workspace, it
/// flickers still. Like this was a problem from before."
///
/// The workspace card is interactive (#28897: its tabs are one click away), and its window is the
/// card plus a clear band about 50 pt wide that lies over the trailing part of the hovered row. A
/// window that takes the mouse there took it from the sidebar: the list saw the pointer leave its
/// row while it still moved over it (the row's hover went off and on), and the pointer's moves in
/// the band reached no source, so near the row's top or bottom edge the card hid after the reshow
/// window and showed again when the pointer moved back.
///
/// `deliver` routes each pointer point as the window server does: to the card's window when that
/// window takes the mouse and its frame (the band included) holds the point, else to the list.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHoverCardBandTests {
    private struct Fixture {
        let list: SidebarListView
        let window: NSWindow
        let coordinator: HoverCardCoordinator
        let row: SidebarRow
        /// The pointer is over the card's window (the list got its exit).
        var inCardWindow = false
    }

    /// Five workspaces, the third one selected (the highlighted row Leo moved around).
    private static func fixture(clock: ManualClock) throws -> Fixture {
        _ = NSApplication.shared
        let workspaces = (1...5).map {
            SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace-\($0)", directory: "~/Projects/site-\($0)", branch: "main")
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: WorkspaceID("ws-3"))
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
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        try #require(rows.count == 5)
        return Fixture(list: list, window: window, coordinator: coordinator, row: rows[2])
    }

    private static func tearDown(_ f: Fixture) {
        f.coordinator.dismiss(.action)
        f.coordinator.cardWindow?.closeAfterTest()
        f.window.contentView = nil
        f.window.closeAfterTest()
    }

    /// A list point on screen.
    private static func screen(_ f: Fixture, _ point: NSPoint) -> CGPoint {
        f.window.convertPoint(toScreen: f.list.convert(point, to: nil))
    }

    /// The pointer moves to `screenPoint`, delivered to the window the window server gives it to.
    private static func deliver(_ f: inout Fixture, _ screenPoint: CGPoint) throws {
        let panel = f.coordinator.cardWindow
        let toCard = panel.map { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(screenPoint) } ?? false
        let windowPoint = f.window.convertPoint(fromScreen: screenPoint)
        if toCard {
            if !f.inCardWindow {
                // The list's tracking area: the pointer left for another window.
                let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: windowPoint, modifierFlags: [],
                                                               timestamp: 0, windowNumber: f.window.windowNumber, context: nil,
                                                               eventNumber: 0, trackingNumber: 0, userData: nil))
                f.list.mouseExited(with: exit)
            }
            f.inCardWindow = true
            // The card window's own move, as the coordinator's move monitor sees it.
            f.coordinator.cardPointerMoved(screenPoint)
        } else {
            f.inCardWindow = false
            f.list.updateHover(windowPoint)
        }
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func movingAroundTheSelectedRowAndOntoItsCardNeverHidesOrMovesTheCard() async throws {
        let clock = ManualClock()
        var f = try Self.fixture(clock: clock)
        defer { Self.tearDown(f) }
        let rowFrame = f.list.frame(for: f.row)
        let key = f.row.key

        // Rest on the selected row until its card shows.
        try Self.deliver(&f, Self.screen(f, NSPoint(x: rowFrame.midX, y: rowFrame.midY)))
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<500 where f.coordinator.machine.shownTarget == nil { try await Task.sleep(for: .milliseconds(10)) }
        let shown = try #require(f.coordinator.machine.shownTarget, "resting on the row showed no card")
        let panel = try #require(f.coordinator.panel)
        let card = panel.cardFrame
        try #require(panel.isInteractive, "the workspace card is interactive")
        #expect(panel.ignoresMouseEvents, "the card's window takes the mouse while the pointer is on the row, off the card")

        // Around the row: its leading part, its trailing end under the card window's band, and
        // its top and bottom edges there.
        let around: [NSPoint] = [
            NSPoint(x: rowFrame.minX + 8, y: rowFrame.midY),
            NSPoint(x: rowFrame.maxX - 4, y: rowFrame.midY),
            NSPoint(x: rowFrame.maxX - 4, y: rowFrame.minY + 1),
            NSPoint(x: rowFrame.maxX - 20, y: rowFrame.minY + 1),
            NSPoint(x: rowFrame.maxX - 4, y: rowFrame.maxY - 1),
            NSPoint(x: rowFrame.midX, y: rowFrame.maxY - 1),
            NSPoint(x: rowFrame.maxX - 4, y: rowFrame.minY + 1),
        ]
        for point in around {
            try Self.deliver(&f, Self.screen(f, point))
            #expect(f.list.hoveredKey == key, "the row's hover went off at \(point) (the list saw the pointer leave)")
            #expect(f.coordinator.machine.phase == .shown(shown), "the card left .shown at \(point): \(f.coordinator.machine.phase)")
        }
        // Resting there past the reshow window: the card stays.
        if f.coordinator.machine.armedToken != nil { try await clock.waitForSleeper() }
        clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        await Self.settle()
        #expect(f.coordinator.isShowing(shown.id), "the card hid under a pointer still on its row: \(f.coordinator.machine.phase)")
        #expect(panel.cardFrame == card, "the card moved or resized while the pointer moved around its row")

        // From the row onto the card: it stays where it is and takes the mouse there.
        try Self.deliver(&f, Self.screen(f, NSPoint(x: rowFrame.maxX - 2, y: rowFrame.midY)))
        try Self.deliver(&f, CGPoint(x: card.minX + 2, y: card.maxY - 8))
        try Self.deliver(&f, CGPoint(x: card.minX + 12, y: card.maxY - 12))
        #expect(f.coordinator.isShowing(shown.id), "moving from the row onto its card hid it")
        #expect(panel.cardFrame == card, "moving onto the card moved or resized it")
        #expect(!panel.ignoresMouseEvents, "the card does not take the mouse with the pointer on it")

        // Back onto the row: the same card, and the sidebar has the mouse again.
        try Self.deliver(&f, Self.screen(f, NSPoint(x: rowFrame.maxX - 4, y: rowFrame.midY)))
        try Self.deliver(&f, Self.screen(f, NSPoint(x: rowFrame.maxX - 6, y: rowFrame.midY)))
        #expect(f.coordinator.isShowing(shown.id), "moving back onto the row hid the card")
        #expect(f.list.hoveredKey == key, "the row is not hovered after the pointer came back to it")
        #expect(panel.ignoresMouseEvents, "the card's window still takes the mouse with the pointer back on the row")
        #expect(panel.cardFrame == card)
    }
}
