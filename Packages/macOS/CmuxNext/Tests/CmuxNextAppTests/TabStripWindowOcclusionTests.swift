import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Every shown pane has a tab strip, and each strip's busy spinners stop while its window is
/// covered (cx-qtgj2). Each strip kept an occlusion observer of its own, so a window with N panes
/// had N observers of one notice (STRESS: 12 panes). The strips now follow the window's
/// ``WindowOcclusionFamily`` (one observer per window, PATTERNS.md P3), and each still hears every
/// change of its own window only.
@MainActor @Suite(.serialized) struct TabStripWindowOcclusionTests {
    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func strip(in window: NSWindow) throws -> TabStripView {
        let model = TabStripModel(tabs: [TabItem(id: TabID("tab"), title: "Tab")], selectedID: TabID("tab"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
        try #require(window.contentView).addSubview(strip)
        try #require(!strip.cells.isEmpty, "the strip made no cell for its tab")
        return strip
    }

    @Test func theStripsOfOneWindowShareItsFamilyAndHearOnlyTheirWindow() throws {
        let center = NotificationCenter()
        let measured = Self.window(), other = Self.window()
        let family = WindowOcclusionFamily.of(measured, center: center)
        _ = WindowOcclusionFamily.of(other, center: center)
        let strips = [try Self.strip(in: measured), try Self.strip(in: measured), try Self.strip(in: other)]
        #expect(family.followerCount == 2, "each tab strip kept an occlusion observer of its own")

        // Each cell starts from the opposite of its window's state, so the check holds on a host
        // whose windows never report visible (headless CI) as well as on one where they do.
        let visible = [measured, measured, other].map { $0.occlusionState.contains(.visible) }
        for (strip, isVisible) in zip(strips, visible) {
            for cell in strip.cells.values { cell.isWindowVisible = !isVisible }
        }
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: measured)
        for strip in strips[0...1] {
            #expect(strip.cells.values.allSatisfy { $0.isWindowVisible == visible[0] }, "a strip missed its window's notice")
        }
        #expect(strips[2].cells.values.allSatisfy { $0.isWindowVisible == !visible[2] }, "another window's notice reached a strip")

        // Out of the window: the family has no follower left and observes nothing.
        strips[0].removeFromSuperview()
        strips[1].removeFromSuperview()
        #expect(family.followerCount == 0)
        #expect(!family.isObserving)
    }
}
