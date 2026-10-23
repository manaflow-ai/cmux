import AppKit
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
    /// A window with native overlays over its content (divider lines, the screen switcher).
    final class OccludingWindow: NSWindow, BrowserWindowOcclusionProviding {
        var browserOcclusionRectsInWindow: [CGRect] = []
    }

    /// The app's window with two pages side by side, as the layout places them.
    struct TwoPages {
        /// A plain window (`ShellWindow.setFrame` keeps frames on the test screen, which can undo a
        /// move) that reports native overlays over its pages, as the app's window does.
        let window: OccludingWindow
        let left = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let right = CEFHostView(frame: CGRect(x: 400, y: 0, width: 400, height: 500))
        /// Both pages' common ancestor below the content view (the layout root's place).
        let stage = NSView()

        init() {
            _ = NSApplication.shared
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window = OccludingWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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

    @Test func aHiddenPagePostsOnceNotOnEveryRequest() {
        let pages = TwoPages()
        pages.forkReads()
        // The fork hides the page window and reads nothing from a hidden host.
        pages.left.isHidden = true
        #expect(pages.posts { pages.requestPageUpdate() } == 1, "the hide reaches the fork")
        #expect(pages.posts { pages.requestPageUpdate() } == 0, "a page still hidden has nothing new")
    }

    /// A divider line coming over one page (a window occlusion rect) reaches only that page.
    @Test func aWindowOverlayOverOnePageReachesOnlyThatPage() {
        let pages = TwoPages()
        pages.forkReads()
        pages.window.browserOcclusionRectsInWindow = [CGRect(x: 100, y: 0, width: 2, height: 500)]
        #expect(pages.posts { pages.requestPageUpdate() } == 1, "only the page under the line")
    }

    /// A corner radius coming to an ancestor moves no frame and changes both pages' clip.
    @Test func aClipChangeWithoutAMoveReachesThePages() {
        let pages = TwoPages()
        pages.stage.wantsLayer = true
        pages.forkReads()
        pages.stage.layer?.cornerRadius = 12
        pages.stage.layer?.masksToBounds = true
        #expect(pages.posts { pages.requestPageUpdate() } == 2, "both pages lose a corner")
    }

    /// A page window moved by another app: the forced request reaches every page, moved or not.
    @Test func aForcedRequestReachesEveryPage() {
        let pages = TwoPages()
        pages.forkReads()
        #expect(pages.posts { pages.requestPageUpdate(force: true) } == 2)
    }
}
