import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// p03-rendering-036 through a real `PaneHostView` (the fakes are `PageSpringResizeTests`'): the rest size
/// `announceRest` hands a page at a spring's start, and the render-server move `placeAtRest` starts and its
/// landing or a take-back ends, which hides a page in its own window only while the pane shows it moving.
@MainActor @Suite(.serialized) struct PageSpringPaneHostTests {
    /// A page that counts the sizes it laid out at.
    final class Page: NSView {
        private(set) var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    static let resizing = PageSpringResizing(mode: { .once })

    /// A pane host as the layout makes it, with no padding, around `content`.
    static func host(_ content: NSView, frame: CGRect, pageResizing: PageSpringResizing? = resizing) -> PaneHostView {
        let host = PaneHostView(pane: PaneID("page"), content: content, pageResizing: pageResizing)
        host.frame = frame
        host.applyShape(padding: 0, cornerRadius: 0)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Cmd-D on the main thread's spring: the host hears its rest size, announces it to the WebKit page, which
    /// takes it once at the start; the spring's frames and its landing resize nothing more.
    @Test func aWebKitPageInAPaneHostResizesOnceAtTheStart() {
        let page = Page(frame: .zero)
        let container = WebKitPageContainer(page: page)
        let host = Self.host(container, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(container.springPlacement === host)
        #expect(page.sizes.last == CGSize(width: 400, height: 300))

        host.restSize = CGSize(width: 200, height: 300)
        host.isOnLayoutSpring = true
        host.announceRest()
        #expect(page.frame.size == CGSize(width: 200, height: 300), "the rest size at the start")
        for width in [360.0, 300, 240, 200] as [CGFloat] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
        }
        host.isOnLayoutSpring = false
        #expect(page.sizes == [CGSize(width: 400, height: 300), CGSize(width: 200, height: 300)])
        #expect(page.frame == container.bounds)
    }

    /// A render-server spring that only moves the pane (a column shifting after a close): no size changes, so
    /// `announceRest` tells the content nothing, but the page window over it hides while the move shows, and
    /// shows again at the landing.
    @Test func aMoveOnlyRenderSpringHidesAPageInItsOwnWindowUntilItLands() {
        let page = CEFHostView(frame: .zero)
        let host = Self.host(page, frame: CGRect(x: 300, y: 0, width: 300, height: 300))
        #expect(page.drawsInChildWindow)
        let move = SplitMotion.RenderMove(from: CGRect(x: 300, y: 0, width: 300, height: 300), to: CGRect(x: 0, y: 0, width: 300, height: 300),
                                          fromAlpha: 1, toAlpha: 1)

        host.placeAtRest(move, laysOut: true)
        #expect(host.showsRenderMove)
        #expect(page.childWindowPage.occlusionRects() == [page.bounds], "hidden while the pane shows where it was")
        #expect(page.frame.size == CGSize(width: 300, height: 300), "a move resizes nothing")

        // Reduce Motion: the move shows in one frame, and the spring lands in this turn.
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        host.springToRest(move, spring: Motion.panes.renderSpring(.scroll), inPlane: { _, _ in nil }, landed: {})
        #expect(!host.showsRenderMove)
        #expect(page.childWindowPage.occlusionRects() != [page.bounds], "shown again where the pane landed")
    }

    /// The main thread takes the render spring back (a structural change mid-spring): the page window follows
    /// the pane's frames from then on, so it shows before the spring's completion runs.
    @Test func aTakeBackShowsThePageWindow() {
        let page = CEFHostView(frame: .zero)
        let host = Self.host(page, frame: CGRect(x: 300, y: 0, width: 300, height: 300))
        let move = SplitMotion.RenderMove(from: CGRect(x: 300, y: 0, width: 300, height: 300), to: CGRect(x: 0, y: 0, width: 300, height: 300),
                                          fromAlpha: 1, toAlpha: 1)

        host.placeAtRest(move, laysOut: true)
        #expect(page.childWindowPage.occlusionRects() == [page.bounds])
        host.stopRenderMoves()
        #expect(page.childWindowPage.occlusionRects() != [page.bounds])
    }

    /// Without the feature the host tells its content nothing about render moves.
    @Test func withoutTheFeatureARenderSpringLeavesThePageWindowAlone() {
        let page = CEFHostView(frame: .zero)
        let host = Self.host(page, frame: CGRect(x: 300, y: 0, width: 300, height: 300), pageResizing: nil)
        let move = SplitMotion.RenderMove(from: CGRect(x: 300, y: 0, width: 300, height: 300), to: CGRect(x: 0, y: 0, width: 300, height: 300),
                                          fromAlpha: 1, toAlpha: 1)

        host.placeAtRest(move, laysOut: true)
        #expect(!page.isOnRenderMove)
        #expect(page.childWindowPage.occlusionRects() != [page.bounds])
    }
}
