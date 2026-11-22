import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// R109 `sidebar.side`: the window root puts the sidebar on the chosen edge
/// and the workspace layout and title beside it.
@MainActor @Suite struct WindowRootSidebarSideTests {
    private func root(_ side: SidebarSide) -> WindowRootView {
        let model = SidebarModel()
        model.width = 240
        let root = WindowRootView(sidebar: SidebarContainerView(model: model), reduceTransparency: { false }, applyWindowBlur: { _, _ in })
        root.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        root.sidebarSide = side
        root.layoutSubtreeIfNeeded()
        return root
    }

    @Test func leftIsTheDefault() {
        let root = root(.left)
        #expect(root.sidebar.frame.minX == 0 && root.sidebar.frame.width == 240)
        #expect(root.contentHost.frame.minX == 240 && root.contentHost.frame.maxX == 1000)
        #expect(root.sidebar.side == .left)
    }

    @Test func rightPutsTheSidebarOnTheTrailingEdge() {
        let root = root(.right)
        #expect(root.sidebar.frame.maxX == 1000 && root.sidebar.frame.width == 240)
        #expect(root.contentHost.frame.minX == 0 && root.contentHost.frame.maxX == 760)
        #expect(root.titlebar.frame.maxX <= 760.5)
        #expect(root.sidebar.side == .right)
        // The traffic lights are not over a right sidebar's header.
        #expect(!root.sidebar.sidebarView.headerHasWindowControls)
    }

    @Test func switchingBackRestoresTheLeftLayout() {
        let root = root(.right)
        root.sidebarSide = .left
        root.layoutSubtreeIfNeeded()
        #expect(root.sidebar.frame.minX == 0 && root.contentHost.frame.minX == 240)
    }

    /// Counts layout passes (the workspace layout re-syncs pane overlays and
    /// strips under the traffic lights in its layout).
    private final class LayoutCounter: NSView {
        var passes = 0
        override func layout() {
            super.layout()
            passes += 1
        }
    }

    @Test func aSideSwitchLaysOutTheMovedContent() {
        let root = root(.left)
        let content = LayoutCounter()
        root.show(content)
        root.layoutSubtreeIfNeeded()
        let before = content.passes
        root.sidebarSide = .right
        #expect(content.passes > before, "the content moved without a size change and must still lay out")
        #expect(content.convert(content.bounds, to: root).minX == 0)
    }
}
