import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// Dogfood (2026-10-01): "consider if window/pane/column moves when mouse
/// doesnt move at all, via scroll etc." Tracking areas send no enter or
/// exit when content moves under a still pointer, so the strip must hit-test
/// the last pointer location again after its own geometry changes.
@MainActor @Suite struct HoverStillPointerTests {
    @Test func scrollingTheStripUnderAStillPointerMovesTheHover() throws {
        let tabs = (0..<40).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: TabID("t0"))
        let strip = TabStripView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        strip.frame = NSRect(x: 0, y: 0, width: 500, height: TabStripView.preferredHeight)
        window.contentView.addSubview(strip)
        strip.layoutSubtreeIfNeeded()
        strip.sync(fromModel: true)
        // The pointer rests on the second visible tab.
        let first = try #require(strip.cells[TabID("t1")])
        let point = strip.tabsClip.convert(CGPoint(x: first.frame.midX, y: first.frame.midY), to: strip)
        // The pointer stays at `point` (screen coordinates for the coordinator).
        let screenPoint = window.convertPoint(toScreen: strip.convert(point, to: nil))
        strip.hoverCards.pointerLocation = { screenPoint }
        strip.hoverCards.windowNumberAt = { _ in window.windowNumber }
        strip.hoverCards.appIsActive = { true }
        strip.updateHover(at: point, moved: true)
        #expect(strip.hoveredID == TabID("t1"))
        #expect(strip.hoverCards.machine.activeTarget?.id == TabHoverCardController.targetID("t1"))
        // The strip scrolls to its last tab; the pointer does not move.
        strip.reveal(TabID("t39"), animated: false)
        strip.applyFrames()
        let under = strip.tabID(at: point)
        #expect(under != TabID("t1"), "the strip scrolled")
        #expect(strip.hoveredID == under, "the hover follows what is under the still pointer, not the tab that moved away")
        #expect(strip.hoverCards.machine.activeTarget?.id == under.map(TabHoverCardController.targetID),
                "the card follows too: no stale card for the tab that moved away")
    }
}
