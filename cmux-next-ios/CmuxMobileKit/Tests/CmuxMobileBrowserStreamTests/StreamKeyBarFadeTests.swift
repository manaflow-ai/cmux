#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileBrowserStream

/// The streamed page's key bar fades its keys at the scroller's edges, as the
/// terminal's key row does, instead of cutting them (user report 2026-11-11: the
/// Copy key was cut in half next to Hide Keyboard).
@MainActor
@Suite struct StreamKeyBarFadeTests {
    /// The terminal key row's fade width (`KeyRowFade.width`).
    private let fadeWidth: CGFloat = 24

    /// The key scroller's mask, as drawn: the left and right edges' opacities.
    private func edges(_ bar: UIView) -> (left: CGFloat, right: CGFloat)? {
        guard let scroll = bar.subviews.compactMap({ $0 as? UIScrollView }).first,
              let mask = scroll.layer.mask as? CAGradientLayer,
              let colors = mask.colors as? [CGColor], colors.count >= 2 else { return nil }
        return (colors[0].alpha, colors[colors.count - 1].alpha)
    }

    private func keyScroller(_ bar: UIView) -> UIScrollView? {
        bar.subviews.compactMap { $0 as? UIScrollView }.first
    }

    @Test func keysFadeAtTheEdgeWithMoreKeysPastIt() throws {
        // Narrower than the keys: they scroll.
        let bar = StreamKeyBar(target: nil)
        bar.frame = CGRect(x: 0, y: 0, width: 240, height: 46)
        bar.layoutIfNeeded()
        let scroll = try #require(keyScroller(bar))
        #expect(scroll.contentSize.width > scroll.bounds.width + 2 * fadeWidth)

        // At the start: the left edge is crisp, the right one fades.
        var drawn = try #require(edges(bar), "the key scroller has no edge fade")
        #expect(drawn.left == 1)
        #expect(drawn.right == 0)

        // In the middle: both fade.
        scroll.contentOffset.x = ((scroll.contentSize.width - scroll.bounds.width) / 2).rounded()
        scroll.layoutIfNeeded()
        drawn = try #require(edges(bar))
        #expect(drawn.left == 0)
        #expect(drawn.right == 0)

        // At the end: the last key is whole, the left edge fades.
        scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width
        scroll.layoutIfNeeded()
        drawn = try #require(edges(bar))
        #expect(drawn.left == 0)
        #expect(abs(drawn.right - 1) < 0.001)

        // Half the fade's width from the end: half faded.
        scroll.contentOffset.x -= fadeWidth / 2
        scroll.layoutIfNeeded()
        drawn = try #require(edges(bar))
        #expect(abs(drawn.right - 0.5) < 0.01)
    }

    @Test func allKeysShowingNothingFades() throws {
        let bar = StreamKeyBar(target: nil)
        bar.frame = CGRect(x: 0, y: 0, width: 1400, height: 46)
        bar.layoutIfNeeded()
        let drawn = try #require(edges(bar), "the key scroller has no edge fade")
        #expect(drawn.left == 1)
        #expect(drawn.right == 1)
    }
}
#endif
