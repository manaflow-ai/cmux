import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// HOT PATH AUDIT frames (cef-geometry): on a layout motion frame the window asks every Chromium page of the window to
/// re-apply its geometry, and every page worked out its whole geometry (`CEFHostGeometry`: ancestor walks for its rect,
/// its visible rect and its clip inputs, and the window's occluders) only to find that it had not moved. With 8 pages
/// and 1 moved that was 8 builds per frame (count probe, fleet job 72743a2b85f7bb70df891cc3). A motion frame's request
/// (`browserPagesGeometryOnlyKey`) now works out the geometry of the pages whose rect, window, scale, hidden state or
/// occluders changed: 1 build for 1 moved page.
@MainActor @Suite(.serialized, .closesItsWindows) struct PageGeometryMovedOnlyTests {
    /// The app's window shape: a window that names its native occluders (divider lines).
    final class OccludingWindow: NSWindow, BrowserWindowOcclusionProviding {
        var occluders: [CGRect] = []
        var browserOcclusionRectsInWindow: [CGRect] { occluders }
    }

    struct EightPages {
        let window: OccludingWindow
        let stage = NSView()
        let pages: [CEFHostView]

        init() {
            _ = NSApplication.shared
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
            window = OccludingWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = content
            _ = WindowOverlayHost.host(for: window)
            stage.frame = content.bounds
            content.addSubview(stage)
            pages = (0..<8).map { index in
                CEFHostView(frame: CGRect(x: CGFloat(index % 4) * 400, y: CGFloat(index / 4) * 500, width: 396, height: 496))
            }
            for page in pages { stage.addSubview(page) }
            forkReads()
        }

        /// What the fork's tracker reads on an update of a shown page.
        func forkReads() {
            for page in pages {
                _ = page.cmuxOcclusionRects()
                _ = page.cmuxClipPath()
            }
        }

        /// One motion frame's request, as the window's overlay layer sends it; returns the builds and the posts.
        func motionFrame() -> (builds: Int, posts: Int) {
            let before = CEFHostView.trackerStats
            // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                            userInfo: [browserPagesGeometryOnlyKey: true])
            let after = CEFHostView.trackerStats
            return (after.geometryBuilds - before.geometryBuilds, after.geometryPosts - before.geometryPosts)
        }

        func tearDown() {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.closeAfterTest()
            panel?.close()
        }
    }

    @Test func aMotionFrameWorksOutTheGeometryOfTheMovedPageOnly() {
        let pages = EightPages()
        defer { pages.tearDown() }
        pages.pages[0].frame.size.width -= 8
        let frame = pages.motionFrame()
        print("HPA-COUNT case=cef-geometry-moved-only pages=8 moved=1 geometry_builds=\(frame.builds) posts=\(frame.posts)")
        #expect(frame.posts == 1)
        #expect(frame.builds == 1, "1 page moved, \(frame.builds) pages worked out their geometry")
    }

    @Test func aStillFrameWorksOutNoGeometry() {
        let pages = EightPages()
        defer { pages.tearDown() }
        let frame = pages.motionFrame()
        #expect(frame.posts == 0)
        #expect(frame.builds == 0)
    }

    /// A divider line that moves over a page that did not move changes what the fork masks: that page posts.
    @Test func anOccluderMovingOverAStillPageReachesIt() {
        let pages = EightPages()
        defer { pages.tearDown() }
        let still = pages.pages[5]
        let inWindow = still.convert(still.bounds, to: nil)
        pages.window.occluders = [CGRect(x: inWindow.minX + 10, y: inWindow.minY, width: 4, height: inWindow.height)]
        let frame = pages.motionFrame()
        #expect(frame.posts == 1, "the line now over page 5 did not reach it")
    }

    /// A page hidden in place (its tab parked) posts its hide once, as before.
    @Test func aHiddenPageStillPostsItsHide() {
        let pages = EightPages()
        defer { pages.tearDown() }
        pages.pages[2].isHidden = true
        #expect(pages.motionFrame().posts == 1)
        #expect(pages.motionFrame().posts == 0)
    }
}
