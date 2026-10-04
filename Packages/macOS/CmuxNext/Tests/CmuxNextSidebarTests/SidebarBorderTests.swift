import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// `sidebar.border` and `sidebar.borderWidth` (R93): an optional line on the
/// sidebar's trailing edge. Off (the default) the edge shows a line only on
/// hover or while dragging; on, the line stays at rest.
@MainActor @Suite(.serialized) struct SidebarBorderTests {
    private func handle(of container: SidebarContainerView) throws -> SidebarResizeHandle {
        try #require(container.subviews.compactMap { $0 as? SidebarResizeHandle }.first)
    }

    private func withSidebarBorder(_ border: SidebarBorder, _ body: () throws -> Void) rethrows {
        let saved = DesignSettings.shared.sidebarBorder
        let savedBorders = DesignSettings.shared.borders
        defer {
            DesignSettings.shared.sidebarBorder = saved
            DesignSettings.shared.borders = savedBorders
        }
        DesignSettings.shared.sidebarBorder = border
        try body()
    }

    @Test func offByDefaultTheEdgeShowsNoLineAtRest() throws {
        #expect(SidebarBorder() == SidebarBorder(shows: false, width: nil))
        try withSidebarBorder(SidebarBorder()) {
            #expect(Metrics.sidebarBorderWidth == 0)
            let handle = try handle(of: SidebarContainerView(model: SidebarModel()))
            #expect(!handle.isLineVisible)
            handle.setHovered(true)
            #expect(handle.isLineVisible)
        }
    }

    @Test func onTheLineStaysAtRestWithItsWidth() throws {
        try withSidebarBorder(SidebarBorder(shows: true, width: 2)) {
            #expect(Metrics.sidebarBorderWidth == 2)
            let handle = try handle(of: SidebarContainerView(model: SidebarModel()))
            #expect(handle.isLineVisible)
            #expect(handle.lineWidth == 2)
        }
    }

    @Test func onWithoutAWidthIsTheDividerHairline() throws {
        try withSidebarBorder(SidebarBorder(shows: true)) {
            #expect(Metrics.sidebarBorderWidth == Metrics.dividerThickness)
        }
    }

    /// `appearance.borders` none removes this line too.
    @Test func bordersNoneRemovesTheSidebarBorder() throws {
        try withSidebarBorder(SidebarBorder(shows: true, width: 2)) {
            DesignSettings.shared.borders = .none
            #expect(Metrics.sidebarBorderWidth == 0)
        }
    }

    /// The handle follows a live settings change without a relaunch.
    @Test func theHandleFollowsALiveChange() throws {
        let handle = SidebarResizeHandle(frame: NSRect(x: 0, y: 0, width: 7, height: 300))
        handle.restingLineWidth = 1
        #expect(handle.isLineVisible)
        handle.restingLineWidth = 0
        #expect(!handle.isLineVisible)
    }
}
