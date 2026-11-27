import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// #37011 / #37010: screen hit-testing can enter or exit a tab strip on a MouseMoved event.
/// With closing mode's extended tracking area installed, reading that event's trackingArea traps in AppKit.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TabStripForwardedPointerTests {
    @Test func mouseMovesEnterAndLeaveClosingModeStripsThroughTheScreen() throws {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c0", width: 0.5, root: .leaf("p1")),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p2")),
        ])
        let rig = PaneGroundCoversPaneTests.Rig(layout, focused: "p1")
        defer { rig.close() }
        rig.window.orderFrontRegardless()
        rig.window.displayIfNeeded()
        let screen = try rig.screen
        let strips = try ["p1", "p2"].map { name -> TabStripView in
            let host = try #require(rig.root.context.hosts[PaneID(name)])
            return try #require(PaneMotionPointerAreasTests.first(TabStripView.self, in: host))
        }
        defer { for strip in strips { strip.closingWatch.end() } }
        for strip in strips { try installClosingWatch(in: strip) }

        func move(to strip: TabStripView) throws {
            let cell = try #require(strip.cells[TabID("terminal")])
            let point = strip.tabsClip.convert(NSPoint(x: cell.frame.midX, y: cell.frame.midY), to: nil)
            let event = try mouseMove(at: point, in: rig.window)
            screen.dividerPointer.mouseMoved(with: event)
            #expect(screen.dividerPointer.contentTarget === strip)
            #expect(strip.hoveredID == TabID("terminal"))
            #expect(strip.buttonReveal.pointerInStrip)
            #expect(strip.closingModeWidth != nil)
        }

        try move(to: strips[0]) // First MouseMoved is a hit-tested enter, with the closing watch active.
        try move(to: strips[0]) // An ordinary move inside the same strip still updates hover.
        try move(to: strips[1]) // The same MouseMoved exits one strip and enters the other.
        #expect(strips[0].hoveredID == nil)
        #expect(!strips[0].buttonReveal.pointerInStrip)
        try move(to: strips[0]) // Return while the extended closing-mode watch remains installed.
        #expect(strips[1].hoveredID == nil)
    }

    @Test(arguments: [true, false])
    func appKitOverridesDoNotReadTrackingMetadataFromMouseMoves(entered: Bool) throws {
        _ = NSApplication.shared
        let harness = TabStripRapidCloseTests.Harness(count: 3)
        let strip = harness.strip
        defer { harness.window.closeAfterTest() }
        defer { strip.closingWatch.end() }
        try installClosingWatch(in: strip)
        let cell = try #require(strip.cells[TabID("tab0")])
        let point = strip.tabsClip.convert(NSPoint(x: cell.frame.midX, y: cell.frame.midY), to: nil)
        let event = try mouseMove(at: point, in: harness.window)
        strip.mouseMoved(with: event)
        if entered { strip.mouseEntered(with: event) } else { strip.mouseExited(with: event) }
        #expect(strip.hoveredID == (entered ? TabID("tab0") : nil))
        #expect(strip.buttonReveal.pointerInStrip == entered)
    }

    private func installClosingWatch(in strip: TabStripView) throws {
        strip.closingModeWidth = 100
        strip.closingWatch.pointerLeft()
        let host = try #require(strip.window?.contentView)
        try #require(host.trackingAreas.contains { ($0.owner as? TabStripView) === strip },
                     "The crash needs the extended closing-mode tracking area, not just ordinary strip hover")
    }

    private func mouseMove(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 0, pressure: 0))
    }
}
