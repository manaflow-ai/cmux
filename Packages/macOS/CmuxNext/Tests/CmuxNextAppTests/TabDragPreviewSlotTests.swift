import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A tab dragged over another pane's tab bar previews where it lands: in a gap of its own width, its ghost drawn in
/// that gap. In a crowded bar the gap took the squeezed width of the bar's tabs, so the ghost's picture was squeezed
/// too; and over a bar at the top of a screen the ghost hung below the bar.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct TabDragPreviewSlotTests {
    /// A bar of `count` tabs in a 1200-point window: with many, each tab is narrower than its full width.
    private static func crowded(_ count: Int) throws -> (PaneCloseControllerTests.Shown, TabStripView) {
        let tabs = (1...count).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "Tab \($0)") }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)])
        let shown = try PaneCloseControllerTests.Shown(tree: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen]),
        ]))
        let strip = try shown.controller(1).view.stripView
        strip.syncFromModel()
        return (shown, strip)
    }

    @Test func aDraggedTabOpensAGapOfItsOwnWidthInACrowdedBar() throws {
        let (shown, strip) = try Self.crowded(24)
        defer { shown.end() }
        let point = shown.window.convertPoint(toScreen: strip.convert(CGPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil))
        let squeezed = try #require(strip.dropHitTest(screenPoint: point, payload: .tab(id: "incoming", sourceStripID: UUID()))?.ghostFrame)
        strip.dropExited()
        let width: CGFloat = 180
        try #require(squeezed.width < width - 1, "the bar is not crowded: an unsized gap is \(squeezed.width) wide")
        let sized = try #require(strip.dropHitTest(screenPoint: point, payload: .tab(id: "incoming", sourceStripID: UUID(), width: width))?.ghostFrame)
        #expect(abs(sized.width - width) <= 0.5, "the gap is \(sized.width) wide, not the dragged tab's \(width)")
        strip.dropExited()
        #expect(strip.groups.phantomTabWidth == nil, "the gap's width outlived the drag")
    }

    /// The ghost's panel stays where it is put when its shadow room reaches above the screen's visible area (a tab bar
    /// at the top of a screen, under the menu bar): AppKit's constraint moved it down, off the gap.
    @Test func theGhostKeepsItsPlaceUnderTheMenuBar() throws {
        let screen = try #require(NSScreen.main)
        let ghost = TabDragGhostPanel(tabImage: nil, tabSize: CGSize(width: 180, height: 30), grabOffset: .zero, aspect: nil, scale: 2,
                                      onGlass: false)
        defer { ghost.panel.orderOut(nil); ghost.panel.close() }
        ghost.panel.orderFrontRegardless()
        let size = ghost.panel.frame.size
        let origin = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - size.height + 24)
        ghost.panel.setFrameOrigin(origin)
        #expect(ghost.panel.frame.origin == origin, "the ghost moved from \(origin) to \(ghost.panel.frame.origin)")
        let above = NSRect(origin: origin, size: size)
        #expect(ghost.panel.constrainFrameRect(above, to: screen) == above)
    }
}
