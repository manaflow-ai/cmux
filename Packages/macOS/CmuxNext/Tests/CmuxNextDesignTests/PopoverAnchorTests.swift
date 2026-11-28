import AppKit
import Testing
@testable import CmuxNextDesign

@MainActor @Suite struct PopoverAnchorTests {
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test func menuPointUsesTheTriggerCoordinateSpaceAndSharedGap() {
        let view = FlippedView(frame: NSRect(x: 12, y: 24, width: 80, height: 30))
        #expect(CmuxPopoverAnchor.menuPoint(in: view) == NSPoint(x: 0, y: 36))
        #expect(CmuxPopoverAnchor.rect(in: view) == NSRect(x: 0, y: 0, width: 80, height: 30))
    }

    @Test func unflippedViewsOpenOnTheSameVisualSide() {
        let view = NSView(frame: NSRect(x: 12, y: 24, width: 80, height: 30))
        #expect(CmuxPopoverAnchor.menuPoint(in: view) == NSPoint(x: 0, y: -6))
        #expect(CmuxPopoverAnchor.menuPoint(in: view, gap: 4, edge: .minY) == NSPoint(x: 0, y: 34))
    }
}
