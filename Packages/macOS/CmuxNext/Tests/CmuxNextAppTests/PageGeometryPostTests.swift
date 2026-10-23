import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Lawrence (2026-10-23): "making splits in general has laggy animation, even more laggy if there
/// are CEF chromium views involved". On every motion frame the window asks its Chromium pages to
/// re-apply their geometry (`browserChildWindowPagesNeedUpdate`: the divider lines moved), and every
/// page posted the fork's geometry notification, so the fork re-read clip and occlusion, rebuilt the
/// mask and moved the page window of every page, the static ones too. A page posts only when what
/// the fork reads (its screen rect, visible rect, clip inputs, occlusion holes) changed since the
/// fork last read it.
@MainActor @Suite struct PageGeometryPostTests {
    /// A plain window (`ShellWindow.setFrame` keeps frames on the test screen, which can undo a
    /// move) with the app window's overlay rects and a backing scale the test sets.
    final class PagesWindow: NSWindow, BrowserWindowOcclusionProviding {
        var browserOcclusionRectsInWindow: [CGRect] = []
        /// Stands in for a move to a display of another scale.
        var scaleOverride: CGFloat?
        override var backingScaleFactor: CGFloat { scaleOverride ?? super.backingScaleFactor }
    }

    /// The app's window with two pages side by side, as the layout places them.
    struct TwoPages {
        let window: PagesWindow
        let left = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let right = CEFHostView(frame: CGRect(x: 400, y: 0, width: 400, height: 500))
        /// Both pages' common ancestor below the content view (the layout root's place).
        let stage = NSView()

        /// - Parameter deferred: the window gets no window server window until it shows, so its
        ///   frame is only this process's (a test window's frame is otherwise the window server's,
        ///   which on some hosts kept it in place: 0 posts for a window move on cmux13s, 5ed2ce6dcad).
        init(deferred: Bool = false) {
            _ = NSApplication.shared
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window = PagesWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: deferred)
            window.isReleasedWhenClosed = false
            window.contentView = content
            _ = WindowOverlayHost.host(for: window)
            stage.frame = content.bounds
            content.addSubview(stage)
            stage.addSubview(left)
            stage.addSubview(right)
        }

        /// What the fork's tracker does on a geometry update: it reads both.
        func forkReads() {
            for page in [left, right] {
                _ = page.cmuxOcclusionRects()
                _ = page.cmuxClipPath()
            }
        }

        /// The fork geometry notifications the pages posted while `body` ran.
        func posts(_ body: () -> Void) -> Int {
            let before = CEFHostView.trackerStats.geometryPosts
            body()
            return CEFHostView.trackerStats.geometryPosts - before
        }

        func requestPageUpdate(force: Bool = false) {
            // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                            userInfo: force ? [browserPagesForceUpdateKey: true] : nil)
        }
    }

    @Test func aPageUpdateWithNothingChangedPostsNothing() {
        let pages = TwoPages()
        pages.forkReads()
        let posted = pages.posts { pages.requestPageUpdate() }
        #expect(posted == 0, "nothing moved since the fork read the pages: \(posted) posts")
    }

    @Test func aPageUpdatePostsOnlyForThePageThatMoved() {
        let pages = TwoPages()
        pages.forkReads()
        // A motion frame: the left page's pane narrows, the right page stays.
        pages.left.frame = CGRect(x: 0, y: 0, width: 360, height: 500)
        // Moving a view posts nothing by itself (the fork observes its frame notifications).
        let posted = pages.posts { pages.requestPageUpdate() }
        #expect(posted == 1, "only the moved page posts: \(posted) posts")
    }

    /// A move of both pages on screen (an ancestor moved, as a window move or a sidebar slide moves
    /// them) reaches each page. An ancestor, not the window: a test window's frame is the window
    /// server's on a host with a display, and the screen rect is what changes either way.
    @Test func aMoveOfBothPagesReachesEveryPage() {
        let pages = TwoPages()
        pages.forkReads()
        pages.stage.setFrameOrigin(CGPoint(x: 40, y: 0))
        let posted = pages.posts { pages.requestPageUpdate() }
        #expect(posted == 2, "both pages moved on screen: \(posted) posts")
    }

    /// A window move changes every page's screen rect: each page re-places its window.
    @Test func aWindowMoveReachesEveryPage() throws {
        let pages = TwoPages(deferred: true)
        pages.forkReads()
        let before = pages.window.frame
        pages.window.setFrame(before.offsetBy(dx: 40, dy: 0), display: false)
        try #require(pages.window.frame.origin.x == before.origin.x + 40, "the test window moved: \(before) -> \(pages.window.frame)")
        let posted = pages.posts { pages.requestPageUpdate() }
        #expect(posted == 2, "both pages moved on screen: \(posted) posts")
    }

    /// An overlay that takes the mouse (the screen switcher) appears over the left page: the fork
    /// must punch its hole there; the right page has nothing new.
    @Test func aWindowOverlayOverOnePageReachesOnlyThatPage() {
        let pages = TwoPages()
        pages.forkReads()
        let overlay = CGRect(x: 100, y: 100, width: 50, height: 50)
        pages.window.browserOcclusionRectsInWindow = [overlay]
        let posted = pages.posts { pages.requestPageUpdate() }
        #expect(posted == 1, "only the page under the overlay posts: \(posted) posts")
        // What the fork reads is the hole the page reports.
        let read = (pages.left.cmuxOcclusionRects() as? [NSValue] ?? []).map(\.rectValue)
        #expect(read == pages.left.allOcclusionRects && read.contains(pages.left.convert(overlay, from: nil)), "fork read \(read)")
    }

    /// The pane corners change (a theme or padding change): both pages under the rounded clip
    /// re-read their clip shape though neither moved.
    @Test func aCornerChangeReachesThePagesUnderTheClip() throws {
        let pages = TwoPages()
        pages.stage.wantsLayer = true
        let layer = try #require(pages.stage.layer)
        layer.masksToBounds = true
        layer.cornerRadius = 0
        pages.forkReads()
        layer.cornerRadius = 12
        #expect(pages.posts { pages.requestPageUpdate() } == 2, "the rounded corners reach both pages")
        pages.forkReads()
        #expect(pages.posts { pages.requestPageUpdate() } == 0, "the same corners again have nothing new")
    }

    /// The window moves to a display of another scale: the fork re-places every page at it.
    @Test func aBackingScaleChangeReachesEveryPage() {
        let pages = TwoPages()
        pages.forkReads()
        pages.window.scaleOverride = pages.window.backingScaleFactor + 1
        #expect(pages.posts { pages.requestPageUpdate() } == 2, "the new scale reaches both pages")
    }

    /// Something other than the fork moved a page window (`WindowOverlayLayer.pageWindowDidChangeFrame`):
    /// the hosts did not move, so only a forced update puts the page windows back.
    @Test func aForcedUpdateReachesEveryPageThatDidNotMove() {
        let pages = TwoPages()
        pages.forkReads()
        #expect(pages.posts { pages.requestPageUpdate(force: true) } == 2, "a forced update reaches both pages")
        #expect(pages.posts { pages.requestPageUpdate() } == 0, "after it, nothing is new")
    }

    @Test func aHiddenPagePostsOnceNotOnEveryRequest() {
        let pages = TwoPages()
        pages.forkReads()
        // The fork hides the page window and reads nothing from a hidden host.
        pages.left.isHidden = true
        #expect(pages.posts { pages.requestPageUpdate() } == 1, "the hide reaches the fork")
        #expect(pages.posts { pages.requestPageUpdate() } == 0, "a page still hidden has nothing new")
    }

    /// A view that clips its subviews the way the fork's visible rect sees it (`clipsToBounds`)
    /// without a layer mask, so the clip shape's inputs (layer masks only) stay the same.
    final class ClippingView: NSView {
        override var clipsToBounds: Bool {
            get { true }
            set {}
        }
    }

    /// A clipping ancestor shrinks while the page keeps its place on screen (a clip view or a
    /// strip edge cutting into the pane): only the visible rect changes, and the fork must re-clip
    /// the page window to it.
    @Test func aClippingAncestorThatShrinksReachesThePageItCuts() throws {
        let pages = TwoPages()
        let clipper = ClippingView(frame: pages.left.frame)
        pages.left.removeFromSuperview()
        pages.left.frame = clipper.bounds
        clipper.addSubview(pages.left)
        pages.stage.addSubview(clipper)
        pages.forkReads()
        let before = CEFHostGeometry(of: pages.left)
        clipper.setFrameSize(NSSize(width: 300, height: 500))
        let after = CEFHostGeometry(of: pages.left)
        try #require(after.screenRect == before.screenRect && after.clip == before.clip,
                     "only the visible rect changes: screen \(before.screenRect) -> \(after.screenRect)")
        try #require(after.visibleInWindow != before.visibleInWindow, "the ancestor cuts the page: \(after.visibleInWindow)")
        #expect(pages.posts { pages.requestPageUpdate() } == 1, "the page whose visible rect changed posts, the other does not")
    }

    /// The fork read a page mid-layout (a page update inside the pass, or a frame notification of
    /// a view the pass moves again), and the pass then put the page back where the fork read it
    /// before. The request after the pass compares with what the fork read last, so it posts.
    @Test func theRequestAfterAStaleMidLayoutReadPosts() {
        let pages = TwoPages()
        pages.forkReads()
        let resting = pages.left.frame
        pages.left.frame = resting.insetBy(dx: 20, dy: 0)
        pages.forkReads()
        pages.left.frame = resting
        #expect(pages.posts { pages.requestPageUpdate() } == 1, "the fork last read the mid-layout frame: the final one must reach it")
        #expect(pages.posts { pages.requestPageUpdate() } == 0, "after it, nothing is new")
    }

    /// A forced update asked for inside the window's layout pass (a page window moved by another
    /// app while the pass runs) waits for the pass, and a plain request in the same pass must not
    /// drop its force: after the pass every page re-places its window, moved or not
    /// (`WindowOverlayLayer.forcedPageUpdateAfterLayout`).
    @Test func aForcedUpdateAskedInsideTheLayoutPassReachesEveryPageAfterIt() {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = content
        let left = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let right = CEFHostView(frame: CGRect(x: 400, y: 0, width: 400, height: 500))
        content.addSubview(left)
        content.addSubview(right)
        for page in [left, right] {
            _ = page.cmuxOcclusionRects()
            _ = page.cmuxClipPath()
        }
        func posts(_ body: () -> Void) -> Int {
            let before = CEFHostView.trackerStats.geometryPosts
            body()
            return CEFHostView.trackerStats.geometryPosts - before
        }
        let layer = window.overlayLayer
        layer.windowWillLayout()
        let inside = posts {
            layer.requestPageUpdate(force: true)
            layer.requestPageUpdate()
        }
        #expect(inside == 0, "nothing reaches the pages inside the layout pass: \(inside) posts")
        let after = posts { layer.windowDidLayout() }
        #expect(after == 2, "the forced update reaches both pages after the pass: \(after) posts")
        #expect(posts { layer.requestPageUpdate() } == 0, "after it, nothing is new")
    }
}
