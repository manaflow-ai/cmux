import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// cx-3wu5: the strip's hover is a function of the pointer now and the strip
/// now. When the strip moves out from under a still pointer (its pane moved,
/// a column scrolled), no exit arrives; the strip must clear everything an
/// exit clears: the plus's hover, the pointer-in-strip reveal and the
/// deferred close-mode width.
@MainActor @Suite struct TabStripHoverOwnerTests {
    @Test func theStripMovingAwayFromAStillPointerClearsThePlusAndTheReveal() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Tab"), TabItem(id: TabID("t1"), title: "Other")],
                                  selectedID: TabID("t0"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
        window.contentView!.addSubview(strip)
        strip.sync(fromModel: true)
        strip.layoutSubtreeIfNeeded()
        let button = strip.newTabButton
        #expect(!button.isHidden)
        // The pointer rests on the plus and never moves again.
        let point = strip.contentView.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: strip)
        let windowPoint = strip.convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        strip.hoverCards.pointerLocation = { screenPoint }
        strip.hoverCards.windowNumberAt = { _ in window.windowNumber }
        strip.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        #expect(button.isHovered)
        #expect(strip.buttonReveal.pointerInStrip)
        strip.closingModeWidth = 300

        // The pane holding the strip moves down: the strip leaves the pointer.
        strip.setFrameOrigin(NSPoint(x: 0, y: 200))
        strip.paneMovedInWindow()

        #expect(!strip.bounds.contains(strip.convert(windowPoint, from: nil)), "the strip moved away from the pointer")
        #expect(!button.isHovered, "the plus is not under the pointer any more")
        #expect(!strip.buttonReveal.pointerInStrip, "the reveal follows the pointer, not the last tracking event")
        #expect(strip.closingModeWidth == nil, "the deferred close-mode width ends as on an exit")
    }
}
