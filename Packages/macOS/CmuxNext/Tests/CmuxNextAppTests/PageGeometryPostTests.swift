import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// Lawrence (2026-10-23): "making splits in general has laggy animation, even more laggy if there
/// are CEF chromium views involved". On every motion frame the window asks its Chromium pages to
/// re-apply their geometry (`NSWindow.updateBrowserPageGeometry`: the divider lines moved), and every
/// page posted the fork's geometry notification, so the fork re-read clip and occlusion, rebuilt the
/// mask and moved the page window of every page, the static ones too. A page posts only when what
/// the fork reads (its screen rect, visible rect, clip inputs, occlusion holes) changed since the
/// fork last read it.
@MainActor @Suite struct PageGeometryPostTests {
    /// The app's window with two pages side by side, as the layout places them.
    struct TwoPages {
        /// A plain window: `ShellWindow.setFrame` keeps frames on the test screen, which can undo a move.
        let window: NSWindow
        /// The pages' own center: the requests of this test reach no other test's observers.
        let center = NotificationCenter()
        let left: CEFHostView
        let right: CEFHostView
        /// Both pages' common ancestor below the content view (the layout root's place).
        let stage = NSView()

        init() {
            _ = NSApplication.shared
            left = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), pageUpdateCenter: center)
            right = CEFHostView(frame: CGRect(x: 400, y: 0, width: 400, height: 500), pageUpdateCenter: center)
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
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

        func requestPageUpdate() {
            window.updateBrowserPageGeometry(center: center)
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
}
