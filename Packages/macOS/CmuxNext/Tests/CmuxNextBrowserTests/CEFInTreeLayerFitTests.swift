import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import QuartzCore
import Testing

/// An in-tree page's drawing layer is its view's size after every resize (in-tree-regressions.md bugs 13, 14, 18).
///
/// Chromium draws a page through `DisplayCALayerTree`: under the `RenderWidgetHostViewCocoa`'s layer, a geometry-flipped
/// layer that follows that layer only by Core Animation autoresizing, anchored at the bottom left, and the page's
/// `CALayerHost` at its top left. Autoresizing adds each size change to the layer's current size, rounded, so in tree,
/// where panes take half-point sizes every frame of a divider drag, a zoom or a window resize, the layer drifts from its
/// view and never comes back. On the other Mac (build 17edc4df, live rows pane_fit.layers.grid0..3) a 266.5 x 353.5 page
/// view had that layer at 290 x 375: the page drew 21.5 pt high (its top cut off), its bottom 21.5 pt never painted, and
/// every click landed 21.5 pt above what it showed.
@MainActor
@Suite(.serialized) struct CEFInTreeLayerFitTests {
    /// A page shaped as Chromium's: a `WebContentsViewCocoa` stand-in holding a layer-hosting view whose layer holds a
    /// flipped, autoresizing layer with a host layer at its origin.
    final class FakePage {
        let contents = NSView()
        let widget = NSView()
        let background = CALayer()
        let flipped = CALayer()
        let host = CALayer()

        init() {
            flipped.isGeometryFlipped = true
            flipped.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            flipped.anchorPoint = .zero
            background.addSublayer(flipped)
            host.anchorPoint = .zero
            host.autoresizingMask = [.layerMaxXMargin, .layerMaxYMargin]
            flipped.addSublayer(host)
            widget.layer = background
            widget.wantsLayer = true
            widget.autoresizingMask = [.width, .height]
            contents.autoresizingMask = [.width, .height]
            contents.addSubview(widget)
        }

        var calls: CEFInTreeCalls {
            CEFInTreeCalls(setInTreeHosting: { [self] _, container in
                guard let container else { return nil }
                if contents.superview !== container {
                    contents.frame = container.bounds
                    widget.frame = contents.bounds
                    container.addSubview(contents, positioned: .below, relativeTo: nil)
                }
                return contents
            }, contentView: { [self] _ in widget })
        }
    }

    private func inTree(_ body: (CEFHostView, FakePage) throws -> Void) rethrows {
        InTreePages.shared.setForTesting(requested: true, engine: .supported)
        defer { InTreePages.shared.setForTesting(requested: nil) }
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = FakePage()
        #expect(host.inTree.pageWindowCreated(browser: 7, calls: page.calls))
        // The request runs at the end of the run-loop turn (CEFInTreeHosting.request).
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        try body(host, page)
    }

    private func settle(_ layer: CALayer) {
        CATransaction.flush()
        layer.layoutIfNeeded()
    }

    @Test func aDrawingLayerOffItsViewsSizeIsPutBackAtTheNextResize() throws {
        try inTree { host, page in
            try #require(host.inTree.isInTree, "the fake page did not go in tree")
            // The drift the live rows read: the flipped layer 23.5 x 21.5 pt larger than its view.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            page.flipped.frame = CGRect(x: 0, y: 0, width: page.background.bounds.width + 23.5,
                                        height: page.background.bounds.height + 21.5)
            CATransaction.commit()
            for size in [NSSize(width: 266.5, height: 353.5), NSSize(width: 300.5, height: 280), NSSize(width: 266.5, height: 353.5)] {
                host.setFrameSize(size)
                settle(page.background)
                #expect(page.widget.frame.size == size)
                #expect(page.flipped.frame == page.background.bounds,
                        "at \(size) the page's drawing layer is \(page.flipped.frame), its view \(page.background.bounds): the page draws off its pane")
            }
        }
    }

    @Test func halfPointResizesKeepTheDrawingLayerOnItsView() throws {
        try inTree { host, page in
            try #require(host.inTree.isInTree, "the fake page did not go in tree")
            // A divider drag: a half-point width and height each frame, out and back.
            var sizes: [NSSize] = []
            for step in 0..<60 { sizes.append(NSSize(width: 400 - Double(step) * 2.5, height: 300 - Double(step) * 1.5)) }
            sizes += sizes.reversed()
            for size in sizes {
                host.setFrameSize(size)
                settle(page.background)
            }
            #expect(page.flipped.frame == page.background.bounds,
                    "after 120 half-point resizes the page's drawing layer is \(page.flipped.frame), its view \(page.background.bounds)")
            #expect(page.host.frame.origin == .zero, "the page's host layer left the drawing layer's top left")
        }
    }

    @Test func aRendererViewANavigationLeftUnderThePageIsFittedToo() throws {
        try inTree { host, page in
            try #require(host.inTree.isInTree, "the fake page did not go in tree")
            // A cross-document navigation leaves the old RenderWidgetHostViewCocoa under the new one for a while (seen in
            // the debug.layers geometry on the other Mac): it is no content view, and its drawing layer drifts as well.
            let old = FakePage()
            old.widget.removeFromSuperview()
            old.widget.frame = page.contents.bounds
            page.contents.addSubview(old.widget, positioned: .below, relativeTo: page.widget)
            for size in [NSSize(width: 266.5, height: 353.5), NSSize(width: 333.5, height: 280.5)] {
                host.setFrameSize(size)
                settle(old.background)
                #expect(old.flipped.frame == old.background.bounds,
                        "at \(size) the old renderer's drawing layer is \(old.flipped.frame), its view \(old.background.bounds)")
            }
        }
    }
}
