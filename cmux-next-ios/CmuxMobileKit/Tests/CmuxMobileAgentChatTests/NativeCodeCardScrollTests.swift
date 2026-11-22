#if os(iOS)
@testable import CmuxMobileMarkdown
import Testing
import UIKit

/// A Feed body's code card scrolls sideways under a trailing fade, a mask on its
/// scroll area. The mask moves with the content in the same frame: when it moved
/// with an implicit 0.25 s animation it trailed the finger, and the code the
/// scroll brought in stayed hidden until the mask caught up (2026-11-18 report).
@MainActor
@Suite struct NativeCodeCardScrollTests {
    @Test func theFadeMaskMovesWithTheScrollAtOnce() throws {
        let markdown = """
        Reported an error: Bash

        ```text
        == space-py-green3: glaeda-gh: waiting on run:manaflow-ai/cmux/44457790772 until 3a9c52fd7d47eb, giving up after 4500s (at 21:40:10)
        ```
        """
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 600))
        let layout = NativeMarkdownLayout.make(markdown: markdown, width: 309, styles: NativeTextStyles(category: .large))
        let view = NativeMarkdownView(frame: CGRect(x: 0, y: 0, width: 309, height: layout.height))
        window.addSubview(view)
        window.isHidden = false
        view.apply(layout)
        window.layoutIfNeeded()
        let card = try #require(view.subviews.first { $0 is NativeCodeCardView }, "a code card")
        let scroll = try #require(card.subviews.compactMap { $0 as? UIScrollView }.first, "its scroll area")
        #expect(scroll.contentSize.width > scroll.bounds.width + 100, "the code is wider than the card")
        CATransaction.flush()

        for x in [80.0, 160.0, 40.0] {
            scroll.contentOffset.x = x
            let mask = try #require(scroll.layer.mask, "the trailing fade while more code is off screen")
            #expect(mask.frame.minX == scroll.bounds.minX, "the mask covers the visible code at x \(x)")
            let animated = mask.animationKeys() ?? []
            #expect(animated.isEmpty, "the mask jumps with the scroll, never animates behind it: \(animated)")
            CATransaction.flush()
        }
        window.isHidden = true
    }
}
#endif
