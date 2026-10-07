import AppKit
import Testing
@testable import CmuxNextDesign

/// The list edge fade shows only on an edge with content hidden beyond it.
@MainActor @Suite struct ScrollEdgeFadeTests {
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    let document = CGRect(x: 0, y: 0, width: 100, height: 1000)
    func edges(_ y: CGFloat, _ height: CGFloat = 200, flipped: Bool = true) -> ScrollEdges {
        ScrollEdges.hidden(visible: CGRect(x: 0, y: y, width: 100, height: height), document: document, isFlipped: flipped)
    }

    @Test func topBottomAndMiddle() {
        #expect(edges(0) == .bottom)
        #expect(edges(400) == [.top, .bottom])
        #expect(edges(800) == .top)
    }

    @Test func contentThatFitsShowsNoFade() {
        #expect(edges(0, 1000) == [])
        #expect(edges(0, 1400) == [])
    }

    @Test func halfPointSlackAndRubberBand() {
        // Rounding within half a point counts as at the end.
        #expect(edges(0.5) == .bottom)
        #expect(edges(0.6) == [.top, .bottom])
        #expect(edges(799.5) == .top)
        #expect(edges(799.4) == [.top, .bottom])
        // Elastic overscroll past either end never shows that end's fade.
        #expect(edges(-40) == .bottom)
        #expect(edges(860) == .top)
        #expect(edges(-40, 1000) == [])
        #expect(edges(60, 1000) == [])
    }

    @Test func unflippedDocumentsGrowUpward() {
        #expect(edges(800, flipped: false) == .bottom)
        #expect(edges(0, flipped: false) == .top)
    }

    @Test func contentInsetsAreNotVisibleArea() {
        let insets = NSEdgeInsets(top: 30, left: 0, bottom: 20, right: 0)
        func edges(_ y: CGFloat) -> ScrollEdges {
            ScrollEdges.hidden(clipBounds: CGRect(x: 0, y: y, width: 100, height: 250), insets: insets, document: document, isFlipped: true)
        }
        // At the top the clip's origin is minus the top inset.
        #expect(edges(-30) == .bottom)
        #expect(edges(-29) == [.top, .bottom])
        // At the bottom the last row sits above the bottom inset.
        #expect(edges(1000 - 250 + 20) == .top)
        #expect(edges(1000 - 250 + 19) == [.top, .bottom])
    }

    /// Each layer's geometry flip flips its space relative to its parent.
    @Test func orientationCombinesEveryAncestorFlip() {
        let root = CALayer()
        let parent = CALayer()
        let host = CALayer()
        root.addSublayer(parent)
        parent.addSublayer(host)
        #expect(!ScrollEdgeFadeView.rendersTopDown(host))
        parent.isGeometryFlipped = true
        #expect(ScrollEdgeFadeView.rendersTopDown(host))
        host.isGeometryFlipped = true
        #expect(!ScrollEdgeFadeView.rendersTopDown(host))
    }

    /// AppKit lays a view's layer space out like the view's coordinates,
    /// so a plain host inside a flipped sidebar renders bottom-up even
    /// though its own layer is geometry-flipped.
    @Test func hostInsideFlippedViewOrientsByItsOwnCoordinates() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        let sidebar = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        sidebar.wantsLayer = true
        window.contentView = sidebar
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 300, height: 200))
        scroll.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let fade = ScrollEdgeFadeView(scrollView: scroll)
        sidebar.addSubview(fade)
        sidebar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let layer = try #require(fade.layer)
        // AppKit flips the plain host's own layer to undo the sidebar's flip.
        #expect(layer.isGeometryFlipped)
        // Any scroll re-reads the orientation.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10))
        let mask = try #require(layer.mask as? CAGradientLayer)
        // Location 0 (the top band) is the view's top: y = 1 in the
        // bottom-up space of a plain view, whatever its own layer flag.
        #expect(!fade.isFlipped)
        #expect(mask.startPoint.y == 1)
        #expect(ScrollEdgeFadeView.rendersTopDown(layer) == fade.isFlipped)
    }

    @Test func maskFollowsTheScrollPositionAndContentSize() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        scroll.documentView = document
        let fade = ScrollEdgeFadeView(scrollView: scroll)
        let layer = try #require(fade.layer)
        let mask = try #require(layer.mask as? CAGradientLayer)
        func alphas() -> [CGFloat] { ((mask.colors as? [CGColor]) ?? []).map(\.alpha) }
        #expect(fade.edges == .bottom)
        #expect(alphas() == [1, 1, 1, 0])
        #expect(mask.frame == layer.bounds)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        #expect(fade.edges == [.top, .bottom])
        #expect(alphas() == [0, 1, 1, 0])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        #expect(fade.edges == .top)
        #expect(alphas() == [0, 1, 1, 1])
        // Content grows: rows are hidden below again.
        document.setFrameSize(NSSize(width: 100, height: 1400))
        #expect(fade.edges == [.top, .bottom])
        // Content shrinks until it fits: no fade at all.
        scroll.contentView.scroll(to: .zero)
        document.setFrameSize(NSSize(width: 100, height: 150))
        #expect(fade.edges == [])
        #expect(alphas() == [1, 1, 1, 1])
    }
}
