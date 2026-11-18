import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Issue #45954: a tab dragged along its own bar reorders in the bar. The press and the drags go through the window
/// (`NSWindow.sendEvent`), as a person's do, so the view the window hits for the press is the one that tracks the drag:
/// the other drag tests call the strip's handlers directly and pass even when the window gives the press to another view.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct TabStripReorderThroughWindowTests {
    @Test func aTabDraggedAlongItsBarReordersInTheBar() async throws {
        let f = try await TabDragFollowsPointerTests.fixture(tabCount: 3)
        defer { f.close() }
        let window = try #require(f.controller.window)
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        let ids = strip.presentedTabIDs
        try #require(ids.count == 3)
        let first = try #require(strip.cells[ids[0]])
        let last = try #require(strip.cells[ids[2]])
        let start = strip.tabsClip.convert(NSPoint(x: first.frame.midX, y: first.frame.midY), to: nil)
        let end = strip.tabsClip.convert(NSPoint(x: last.frame.maxX - 4, y: last.frame.midY), to: nil)
        let hit = window.contentView?.superview?.hitTest(start) ?? window.contentView?.hitTest(start)
        #expect(hit.map { $0 === strip || $0.isDescendant(of: strip) } == true,
                "the press on the first tab hits \(String(describing: hit)), not its strip")
        window.sendEvent(try f.event(.leftMouseDown, at: start))
        f.frame()
        for step in 1...20 {
            let t = CGFloat(step) / 20
            window.sendEvent(try f.event(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y)))
            f.frame()
        }
        #expect(f.services.dragSession.drag == nil, "the tab left its bar: the drag session took it")
        #expect(strip.drag != nil, "the strip is not dragging the tab")
        window.sendEvent(try f.event(.leftMouseUp, at: end))
        f.frame()
        #expect(strip.presentedTabIDs.last == ids[0], "the dragged tab did not move to the end: \(strip.presentedTabIDs) from \(ids)")
    }
}
