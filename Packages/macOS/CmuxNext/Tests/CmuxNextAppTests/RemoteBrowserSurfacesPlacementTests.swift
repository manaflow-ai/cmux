import AppKit
@testable import CmuxNextRemoteBrowser
@testable import CmuxNextRemoteView
import Testing

#if DEBUG
/// p06-scheduler-221: a remote page's popup panels re-placed themselves on every
/// `NSWindow.didUpdateNotification`, once per event of the window (each key typed), to catch a page
/// that moved inside its window. Now the page's rect in its window is read once per turn while a
/// popup is open, and only a changed rect places the panels: an ancestor's move (a sidebar or divider
/// drag) still moves them, keys move nothing.
@MainActor @Suite(.serialized) struct RemoteBrowserSurfacesPlacementTests {
    @Test func popupsFollowAnAncestorMoveOnceAndNeverAWindowUpdate() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let pane = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let page = RemoteBrowserContentView()
        page.frame = pane.bounds
        pane.addSubview(page)
        root.addSubview(pane)
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let host = MockRemoteStreamSource(width: 160, height: 100)
        let surfaces = RemoteBrowserSurfaces(page: page, source: { _ in host }, send: { _, _ in })
        defer { surfaces.closeAll() }
        // A hidden page's popups decode nothing: this test needs no encoder.
        surfaces.setVisible(false)
        surfaces.apply(.show(surface: 1, stream: 2, kind: "page_popup", anchor: CGRect(x: 10, y: 10, width: 160, height: 100),
                             pixelWidth: 160, pixelHeight: 100))
        let placements = surfaces.placements
        let frame = try #require(surfaces.panel(of: 1)?.frame)

        // AppKit posts didUpdate once per event of the window: the stand-in for 100 keys.
        for _ in 0..<100 {
            window.update()
            surfaces.checkPagePlacement()
        }
        #expect(surfaces.placements == placements, "a window update placed the popups again")
        #expect(surfaces.panel(of: 1)?.frame == frame)

        // An ancestor moved: the page's own frame did not change, so nothing told it.
        pane.setFrameOrigin(CGPoint(x: 120, y: 0))
        surfaces.checkPagePlacement()
        #expect(surfaces.placements == placements + 1)
        #expect(surfaces.panel(of: 1)?.frame.minX == frame.minX + 120, "the popup stayed behind the page")

        surfaces.checkPagePlacement()
        #expect(surfaces.placements == placements + 1, "an unchanged page placed its popups again")
    }

    @Test func theLastPopupClosingStopsTheCheck() {
        _ = NSApplication.shared
        let page = RemoteBrowserContentView()
        let host = MockRemoteStreamSource(width: 160, height: 100)
        let surfaces = RemoteBrowserSurfaces(page: page, source: { _ in host }, send: { _, _ in })
        surfaces.setVisible(false)
        surfaces.apply(.show(surface: 1, stream: 2, kind: "autofill", anchor: CGRect(x: 0, y: 0, width: 160, height: 100),
                             pixelWidth: 160, pixelHeight: 100))
        #expect(surfaces.isCheckingPlacement)

        surfaces.apply(.hide(surface: 1))
        #expect(!surfaces.isCheckingPlacement, "a page with no popup still checks its rect every turn")
    }
}
#endif
