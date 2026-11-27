#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct AgentFeedInlineTextTests {
    @Test func sizingProposalsDoNotChangeDisplayedText() throws {
        let view = makeView(String(repeating: "**Feed** keeps [links](https://example.com) readable. ", count: 8))
        let size = view.measure(width: 360)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let displayed = NSAttributedString(attributedString: text.attributedText)

        // SwiftUI probes widths before choosing the row's actual frame.
        // A proposal must not replace the already displayed text or its layout.
        for width: CGFloat in [80, 600, 120, 360, 80, 600] {
            _ = view.measure(width: width)
            #expect(text.attributedText.isEqual(to: displayed))
        }

        let narrowSize = view.measure(width: 120)
        view.frame = CGRect(origin: .zero, size: narrowSize)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(!text.attributedText.isEqual(to: displayed))
        #expect(text.attributedText.string.hasSuffix("… See more"))
    }

    @Test func markdownExpansionUsesRenderedOffsets() throws {
        let view = makeView("**Bold** and [linked text](https://example.com/long-destination)", hasMore: true)
        layout(view, width: 600)
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
        layout(view, width: 600)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let button = try #require(view.subviews.compactMap { $0 as? UIButton }.first)

        #expect(text.attributedText.string == "Hello world 👨‍👩‍👧‍👦")
        #expect(button.isHidden)
        let bold = try #require(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test(arguments: ["Plain text", "**Bold** and `code`", "First\n\nSecond\n", "👨‍👩‍👧‍👦 café مرحبا"])
    func measurementMatchesDisplayedText(source: String) throws {
        let view = makeView(source)
        layout(view, width: 360)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        let fitted = text.sizeThatFits(CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        #expect(view.bounds.height >= fitted.height)
        #expect(view.bounds.height - fitted.height < 2)
    }

    @Test func truncationKeepsFormattingAndComposedCharacters() throws {
        let view = makeView(String(repeating: "**👨‍👩‍👧‍👦 Bold** ", count: 30))
        layout(view, width: 240)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)

        #expect(text.attributedText.string.hasSuffix("… See more"))
        #expect(!text.attributedText.string.contains("**"))
        #expect(!text.attributedText.string.contains("�"))
        // TextKit resolves the leading emoji to Apple Color Emoji during
        // layout; check the bold word rather than the emoji fallback font.
        let boldRange = (text.attributedText.string as NSString).range(of: "Bold")
        try #require(boldRange.location != NSNotFound)
        let bold = try #require(text.attributedText.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont)
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
        layout(view, width: 600)
        let text = try #require(view.subviews.compactMap { $0 as? UITextView }.first)
        #expect(text.attributedText.string == expected)
    }

    @Test func tappingARenderedLinkOpensItsDestination() throws {
        let opened = OpenedURLs()
        let view = AgentFeedInlineTextView()
        view.configure(text: "Read [PR 14342](https://github.com/manaflow-ai/cmux/pull/14342) now",
                       hasMoreText: false, lineLimit: 2, itemID: "link",
                       textStyle: .subheadline, monospaced: false, color: .label,
                       open: {}, openURL: { opened.urls.append($0) })
        let measuredSize = view.measure(width: 600)
        view.frame = CGRect(origin: .zero, size: measuredSize)
        view.layoutIfNeeded()
        let lineY = view.bounds.midY
        let linkPoint = try #require(stride(from: 0, to: view.bounds.width, by: 2)
            .map { CGPoint(x: $0, y: lineY) }
            .first { view.link(at: $0) != nil })

        #expect(view.link(at: CGPoint(x: 1, y: lineY)) == nil)
        #expect(view.activateLink(at: linkPoint))
        #expect(opened.urls == [URL(string: "https://github.com/manaflow-ai/cmux/pull/14342")!])
        #expect(!view.activateLink(at: CGPoint(x: 1, y: lineY)))
        #expect(opened.urls.count == 1)
    }

    @MainActor private final class OpenedURLs {
        var urls: [URL] = []
    }

    private func layout(_ view: AgentFeedInlineTextView, width: CGFloat) {
        view.frame = CGRect(origin: .zero, size: view.measure(width: width))
        view.setNeedsLayout()
        view.layoutIfNeeded()
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
