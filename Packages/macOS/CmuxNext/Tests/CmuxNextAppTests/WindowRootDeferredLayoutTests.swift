import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A right-panel width or a sidebar side change marks the root and lays out in
/// the window's next pass (Chrome lays out once per frame; a forced layout needs a reason the turn
/// reads). Before, both forced a layout of the whole window subtree in the change's turn, once per
/// move of a right-panel resize drag.
@MainActor
@Suite struct WindowRootDeferredLayoutTests {
    private struct Rig {
        let root: WindowRootView
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(),
                                                                mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            // sync-layout: the test starts from a laid-out root, so a later needsLayout is the change's own.
            root.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func aRightPanelWidthLaysOutInTheWindowsPass() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.root.rightPanelWidth = 240
        #expect(rig.root.needsLayout, "the right panel's width forced a layout in its own turn")
        // sync-layout: the test reads the frame the window's pass would place.
        rig.root.layoutSubtreeIfNeeded()
        #expect(rig.root.contentHost.frame.maxX <= rig.root.bounds.width - 240, "the main pane is inset by the panel")
    }

    @Test func aSidebarSideChangeLaysOutInTheWindowsPass() {
        let rig = Rig()
        defer { rig.tearDown() }
        let side: SidebarSide = rig.root.sidebarSide == .left ? .right : .left
        rig.root.sidebarSide = side
        #expect(rig.root.needsLayout, "the sidebar side change forced a layout in its own turn")
        // sync-layout: the test reads the frames the window's pass would place.
        rig.root.layoutSubtreeIfNeeded()
        let sidebar = rig.root.sidebar.frame, card = rig.root.contentHost.frame
        #expect(side == .right ? sidebar.minX >= card.maxX : sidebar.maxX <= card.minX,
                "the sidebar sits on the \(side.rawValue) of the main pane")
    }
}
