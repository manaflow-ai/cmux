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

    #if os(iOS)
    /// Leo, 2026-11-23: "adding attachments shouldn then expand the fucking composer EVEN
    /// TALLER... simply have it within the top part of the composer." The strip's height comes
    /// out of the field's, so the tallest card holds the same height with a file attached.
    @Test func anAttachmentStripTakesItsHeightOutOfTheField() {
        let line: CGFloat = 22
        let strip = ComposerCardMetrics.attachmentStripHeight
        let shared = ComposerFieldHeight.maxLines(6, sharing: strip, lineHeight: line)
        #expect(shared == 3)
        // The card at its tallest: field plus strip within a line of the field alone.
        let alone = CGFloat(6) * line
        #expect(abs(CGFloat(shared) * line + strip - alone) <= line / 2)
        #expect(ComposerFieldHeight.maxLines(6, sharing: 0, lineHeight: line) == 6)
        // Never under two lines, nor over the field's own limit.
        #expect(ComposerFieldHeight.maxLines(6, sharing: 500, lineHeight: line) == ComposerFieldHeight.minSharedLines)
        #expect(ComposerFieldHeight.maxLines(1, sharing: strip, lineHeight: line) == 1)
        // A larger text size gives up fewer lines for the same strip.
        #expect(ComposerFieldHeight.maxLines(6, sharing: strip, lineHeight: 40) == 4)
    }
    #endif

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

    /// ComposerRowLayout asks the draft's height at the inline width and at the full width to
    /// choose one row or two. Answered with the height settled at the field's own width, a
    /// draft that wraps inline but fits the full width flipped between the two layouts forever
    /// (the offline-send hang: "main thread busy for 30.0s"). Each width gets its own height,
    /// and the field's own width keeps its settled one.
    @Test func anotherWidthIsMeasuredAtThatWidth() {
        let draft = "Run the tests and summarize."
        let field = Self.field(draft)
        let font = field.font ?? .preferredFont(forTextStyle: .body)
        let oneLine = ceil((draft as NSString).size(withAttributes: [.font: font]).width)
        let wide = oneLine + 40, narrow = floor(oneLine * 0.6)
        let wideHeight = field.fittingSize(proposedWidth: wide).height
        // Settle the field at a width where the draft wraps.
        field.frame.size.width = narrow
        field.layoutIfNeeded()
        let wrapped = field.fittingSize(proposedWidth: narrow).height
        #expect(wrapped > wideHeight, "the draft wraps at \(narrow) pt")
        #expect(field.fittingSize(proposedWidth: wide).height == wideHeight,
                "asked at \(wide) pt while settled at \(narrow) pt: the height at \(wide) pt")
        #expect(field.fittingSize(proposedWidth: narrow).height == wrapped)
        #expect(field.fittingSize(proposedWidth: nil).height == wrapped, "no width: the settled height")

        // The row's choice, fed the real field, places the draft once and keeps it there: a
        // row whose inline width wraps the draft and whose full width fits it.
        let leading = CGSize(width: 44, height: 44), trailing = CGSize(width: 80, height: 44)
        let rowWidth = narrow + leading.width + trailing.width + 2 * ComposerRowGeometry.spacing
        #expect(rowWidth - 2 * ComposerRowGeometry.textInset >= oneLine, "the full width fits the draft")
        #expect(narrow >= ComposerRowGeometry.minInlineFieldWidth)
        var placed: [Bool] = []
        for _ in 0..<6 {
            let geometry = ComposerRowGeometry.place(width: rowWidth, leading: leading, trailing: trailing,
                                                     fieldHeight: { field.fittingSize(proposedWidth: $0).height },
                                                     lineHeight: wideHeight)
            placed.append(geometry.inline)
            field.frame.size = geometry.field.size
            field.layoutIfNeeded()
        }
        #expect(Set(placed).count == 1, "one row or two, not both in turn: \(placed)")
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
