import AppKit
@testable import CmuxNextRemoteBrowser
@testable import CmuxNextRemoteView
import CmuxNextWakeups
import Testing

#if DEBUG
/// A remote page's popup panels re-placed themselves on every
/// `NSWindow.didUpdateNotification`, once per event of the window (each key typed), to catch a page
/// that moved inside its window; then a run-loop observer read the page's rect on every turn. Now the
/// page's rect is read after each layout pass of its window (its `WindowLayoutPasses`, where an
/// ancestor's move happens) while a popup is open, and only a changed rect places the panels: a
/// sidebar or divider drag still moves them, keys and idle turns read nothing.
@MainActor @Suite(.serialized) struct RemoteBrowserSurfacesPlacementTests {
    /// A window that tells its layout passes, as the app's shell window does.
    private final class PassWindow: NSWindow, WindowLayoutPassHosting {
        let layoutPasses = WindowLayoutPasses()
    }

    @MainActor private final class Rig {
        let window: PassWindow
        let pane: NSView
        let page = RemoteBrowserContentView()
        let surfaces: RemoteBrowserSurfaces

        init() {
            _ = NSApplication.shared
            window = PassWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 500), styleMask: [.titled],
                                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            pane = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
            page.frame = pane.bounds
            pane.addSubview(page)
            root.addSubview(pane)
            window.contentView = root
            window.orderFrontRegardless()
            let host = MockRemoteStreamSource(width: 160, height: 100)
            surfaces = RemoteBrowserSurfaces(page: page, source: { _ in host }, send: { _, _ in },
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            // The page shows. The mock host paints only on damage or a keyframe request, and with no
            // VideoToolbox encoder it sends nothing: placement needs no frame.
            surfaces.apply(.show(surface: 1, stream: 2, kind: "page_popup", anchor: CGRect(x: 10, y: 10, width: 160, height: 100),
                                 pixelWidth: 160, pixelHeight: 100))
        }

        func close() {
            surfaces.closeAll()
            window.orderOut(nil)
        }
    }

    @Test func popupsFollowAnAncestorMoveAtTheLayoutPassOnce() throws {
        let rig = Rig()
        defer { rig.close() }
        let placements = rig.surfaces.placements
        let frame = try #require(rig.surfaces.panel(of: 1)?.frame)

        // A layout pass that moved nothing places nothing.
        rig.window.layoutPasses.didLayout()
        #expect(rig.surfaces.placements == placements, "an unchanged page placed its popups again")

        // An ancestor moved in the window's layout pass: the page's own frame did not change, so nothing else told it.
        rig.pane.setFrameOrigin(CGPoint(x: 120, y: 0))
        rig.window.layoutPasses.didLayout()
        #expect(rig.surfaces.placements == placements + 1)
        #expect(rig.surfaces.panel(of: 1)?.frame.minX == frame.minX + 120, "the popup stayed behind the page")

        rig.window.layoutPasses.didLayout()
        #expect(rig.surfaces.placements == placements + 1, "an unchanged page placed its popups again")
    }

    @Test func aHundredWindowUpdatesAndTurnsRunNoPlacementCheck() throws {
        let rig = Rig()
        defer { rig.close() }
        let placements = rig.surfaces.placements
        let checks = rig.surfaces.placementChecks
        let frame = try #require(rig.surfaces.panel(of: 1)?.frame)
        #expect(!WindowEvents.of(rig.window).isObserving(NSWindow.didUpdateNotification))

        // AppKit posts didUpdate once per event of the window (window.update()): the stand-in for 100 keys,
        // each in its own run-loop turn.
        for _ in 0..<100 {
            rig.window.update()
            _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        }

        #expect(rig.surfaces.placementChecks == checks, "a window update or a turn read the page's rect")
        #expect(rig.surfaces.placements == placements, "a window update or a turn placed the popups again")
        #expect(rig.surfaces.panel(of: 1)?.frame == frame)
    }

    @Test func aHiddenPageReadsNothingAtALayoutPassAndPlacesOnceWhenItShows() throws {
        let rig = Rig()
        defer { rig.close() }
        let frame = try #require(rig.surfaces.panel(of: 1)?.frame)
        rig.surfaces.setVisible(false)
        let checks = rig.surfaces.placementChecks
        let placements = rig.surfaces.placements

        rig.pane.setFrameOrigin(CGPoint(x: 120, y: 0))
        for _ in 0..<10 { rig.window.layoutPasses.didLayout() }
        #expect(rig.surfaces.placementChecks == checks, "a hidden page read its rect")
        #expect(rig.surfaces.placements == placements)

        rig.surfaces.setVisible(true)
        #expect(rig.surfaces.placements == placements + 1, "a page that showed did not place its popups")
        #expect(rig.surfaces.panel(of: 1)?.frame.minX == frame.minX + 120, "the popup stayed where the hidden page was")
    }

    @Test func theLastPopupClosingStopsTheCheck() {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.surfaces.isCheckingPlacement)
        #expect(rig.window.layoutPasses.observerCount == 1)

        rig.surfaces.apply(.hide(surface: 1))
        #expect(!rig.surfaces.isCheckingPlacement, "a page with no popup still checks its rect")
        #expect(rig.window.layoutPasses.observerCount == 0)
    }
}
#endif
