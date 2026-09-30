import AppKit
import Testing
@testable import CmuxNextDesign

/// The list edge fade shows only on an edge with content hidden beyond it.
@MainActor @Suite struct ScrollEdgeFadeTests {
    final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    @Test func hiddenEdgesForEveryScrollPosition() {
        let document = CGRect(x: 0, y: 0, width: 100, height: 1000)
        func edges(_ y: CGFloat, _ height: CGFloat = 200, flipped: Bool = true) -> ScrollEdges {
            ScrollEdges.hidden(visible: CGRect(x: 0, y: y, width: 100, height: height), document: document, isFlipped: flipped)
        }
        #expect(edges(0) == .bottom)
        #expect(edges(400) == [.top, .bottom])
        #expect(edges(800) == .top)
        #expect(edges(0, 1000) == [])
        // Rounding and elastic overscroll count as nothing hidden.
        #expect(edges(0.3) == .bottom)
        #expect(edges(-40) == .bottom)
        // Unflipped documents grow upward.
        #expect(edges(800, flipped: false) == .bottom)
        #expect(edges(0, flipped: false) == .top)
    }

    @Test func maskFollowsTheClipView() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 100, height: 1000))
        scroll.documentView = document
        let fade = ScrollEdgeFade(scrollView: scroll)
        #expect(fade.edges == .bottom)
        let mask = try #require(scroll.layer?.mask as? CAGradientLayer)
        // Location 0 is the top edge of the list on screen.
        #expect(mask.startPoint.y == (scroll.layer?.isGeometryFlipped == true ? 0 : 1))
        #expect(mask.locations?.first?.doubleValue == 0)
        #expect((mask.locations?[2].doubleValue ?? 1) < 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        #expect(fade.edges == [.top, .bottom])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
        #expect(fade.edges == .top)
        document.setFrameSize(NSSize(width: 100, height: 150))
        #expect(fade.edges == [])
    }
}
