@testable import CmuxMobileAgentChat
import CmuxMobileDesign
import CoreGraphics
import Foundation
import Testing
#if os(iOS)
import UIKit
#endif

/// User report 2026-11-12 (iPhone): a multi-line draft ran below the composer's
/// rounded field with the caret line outside it, and "it go down when i y".
/// Every composer grows upward a line at a time to `maxLines`, then keeps that
/// height and scrolls inside; a keystroke that keeps the line count keeps the
/// height (`ComposerFieldHeight`).
@Suite struct ComposerFieldHeightTests {
    let rule = ComposerFieldHeight(lineHeight: 20, verticalInset: 6, maxLines: 6)

    @Test func growsALineAtATimeUpToMaxLinesThenStaysAndScrolls() {
        #expect(rule.height(contentHeight: 0) == rule.minHeight)
        #expect(rule.height(contentHeight: 26) == 26)
        #expect(rule.height(contentHeight: 46) == 46)
        #expect(rule.height(contentHeight: 126) == 126)
        #expect(!rule.scrolls(contentHeight: 126))
        #expect(rule.maxHeight == 126)
        for lines in 7...40 {
            let content = CGFloat(lines) * 20 + 6
            #expect(rule.height(contentHeight: content) == rule.maxHeight)
            #expect(rule.scrolls(contentHeight: content))
        }
    }

    @Test func theSameLineCountKeepsTheSameHeight() {
        // A measured height that wobbles below a point (glyph metrics,
        // trailing spaces) is still the same field.
        #expect(rule.height(contentHeight: 65.2) == rule.height(contentHeight: 65.9))
        #expect(rule.lines(contentHeight: 65.2) == 3)
        #expect(rule.lines(contentHeight: 0) == 1)
    }

    @Test func heightNeverShrinksAsLinesAreAdded() {
        var last: CGFloat = 0
        for lines in 1...20 {
            let height = rule.height(contentHeight: CGFloat(lines) * 20 + 6)
            #expect(height >= last)
            last = height
        }
    }

    @Test func maxLinesIsAtLeastOne() {
        #expect(ComposerFieldHeight(lineHeight: 20, verticalInset: 0, maxLines: 0).maxLines == 1)
    }
}

#if os(iOS)
/// The chat composer's real text view under the rule.
@MainActor
@Suite struct ChatComposerFieldLayoutTests {
    static let width: CGFloat = 300

    static func field(_ text: String) -> ChatComposerTextView {
        let view = ChatComposerTextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = text
        let size = view.fittingSize(proposedWidth: width)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    static func lines(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n")
    }

    @Test func everyComposerSharesOneMaximum() {
        #expect(ChatComposerField.maxLines == ComposerFieldHeight.defaultMaxLines)
    }

    @Test func growsWithEachLineUpToMaxLinesThenStops() {
        var heights: [CGFloat] = []
        for count in 1...10 { heights.append(Self.field(Self.lines(count)).bounds.height) }
        let maxLines = ChatComposerField.maxLines
        for index in 1..<maxLines { #expect(heights[index] > heights[index - 1], "line \(index + 1) grows the field") }
        for index in maxLines..<heights.count { #expect(heights[index] == heights[maxLines - 1], "line \(index + 1) scrolls instead") }
        let view = Self.field(Self.lines(10))
        #expect(view.bounds.height == view.fieldHeight.maxHeight)
        #expect(view.textOverflows)
        #expect(!Self.field(Self.lines(3)).textOverflows)
    }

    /// Six lines fit whole: the field does not scroll until the seventh.
    @Test func maxLinesFitWithoutScrolling() {
        let six = Self.field(Self.lines(ChatComposerField.maxLines))
        #expect(!six.textOverflows, "content \(six.contentSize.height) in \(six.bounds.height)")
        #expect(six.contentOffset.y == -six.adjustedContentInset.top)
        #expect(Self.field(Self.lines(ChatComposerField.maxLines + 1)).textOverflows)
    }

    @Test func aKeystrokeOnTheSameLineKeepsTheHeight() {
        let before = Self.field("maybe ok whoa")
        let after = Self.field("maybe ok whoay")
        #expect(before.bounds.height == after.bounds.height)
        let threeLines = Self.field(Self.lines(3))
        let typed = Self.field(Self.lines(3) + "y")
        #expect(threeLines.bounds.height == typed.bounds.height)
    }

    @Test func theCaretLineStaysInsideTheField() {
        for count in [1, 3, 6, 7, 12] {
            let view = Self.field(Self.lines(count))
            view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
            view.followCaret()
            view.layoutIfNeeded()
            let caret = view.caretRect(for: view.endOfDocument)
            let visible = CGRect(origin: view.contentOffset, size: view.bounds.size)
            // The caret overhangs its line by about a point on each side.
            #expect(caret.minY >= visible.minY - 2 && caret.maxY <= visible.maxY + 2,
                    "caret \(caret) inside \(visible) with \(count) lines")
        }
    }

    @Test func aDraftThatFitsStaysAtItsTop() {
        let view = Self.field(Self.lines(3))
        view.contentOffset = CGPoint(x: 0, y: 30)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.contentOffset.y == -view.adjustedContentInset.top)
    }
}
#endif
