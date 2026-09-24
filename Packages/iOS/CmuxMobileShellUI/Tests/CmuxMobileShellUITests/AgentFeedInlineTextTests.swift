#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct AgentFeedInlineTextTests {
    @Test func markdownExpansionUsesRenderedOffsets() throws {
        let view = makeView("**Bold** and [linked text](https://example.com/long-destination)", hasMore: true)
        _ = view.measure(width: 600)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let button = try #require(view.subviews.compactMap { $0 as? UIButton }.first)

        #expect(text.attributedText.string == "Bold and linked text… See more")
        #expect(!button.isHidden)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 100)
        view.layoutIfNeeded()
        #expect(button.frame.minX > 0)
        #expect(button.frame.maxX <= view.bounds.maxX)
    }

    @Test func shortMarkdownDoesNotOfferExpansion() throws {
        let view = makeView("**Hello** `world` 👨‍👩‍👧‍👦")
        _ = view.measure(width: 600)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let button = try #require(view.subviews.compactMap { $0 as? UIButton }.first)

        #expect(text.attributedText.string == "Hello world 👨‍👩‍👧‍👦")
        #expect(button.isHidden)
        let bold = try #require(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func truncationKeepsFormattingAndComposedCharacters() throws {
        let view = makeView(String(repeating: "**👨‍👩‍👧‍👦 Bold** ", count: 30))
        _ = view.measure(width: 240)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)

        #expect(text.attributedText.string.hasSuffix("… See more"))
        #expect(!text.attributedText.string.contains("**"))
        #expect(!text.attributedText.string.contains("�"))
        let bold = try #require(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test(arguments: [
        ("## Heading", "Heading"),
        ("- First\n- Second", "• First\n• Second"),
        ("1. First\n2. Second", "1. First\n2. Second"),
        ("```swift\nlet x = 1\n```", "let x = 1\n"),
    ])
    func blockSyntaxIsRendered(source: String, expected: String) throws {
        let view = makeView(source)
        _ = view.measure(width: 600)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        #expect(text.attributedText.string == expected)
    }

    private func makeView(_ source: String, hasMore: Bool = false) -> AgentFeedInlineTextView {
        let view = AgentFeedInlineTextView()
        view.configure(text: source, hasMoreText: hasMore, lineLimit: 2,
                       itemID: "markdown", textStyle: .subheadline, monospaced: false,
                       color: .label, open: {})
        return view
    }
}
#endif
