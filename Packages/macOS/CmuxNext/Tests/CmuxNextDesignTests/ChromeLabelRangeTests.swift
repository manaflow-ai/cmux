import AppKit
@testable import CmuxNextDesign
import Testing

/// p10-stability-170: a label's range-taking calls go through CmuxNextCompat's checked helpers, so a range
/// or index outside the text gives nil (the accessibility API) or is skipped, never `NSRangeException`.
@MainActor @Suite struct ChromeLabelRangeTests {
    /// "a😀b" is 4 UTF-16 units: the emoji is a surrogate pair.
    private let label = ChromeLabel(labelWithString: "a😀b")

    @Test func accessibilityStringReadsRangesInsideTheText() {
        #expect(label.accessibilityString(for: NSRange(location: 0, length: 4)) == "a😀b")
        #expect(label.accessibilityString(for: NSRange(location: 3, length: 1)) == "b")
        #expect(label.accessibilityString(for: NSRange(location: 4, length: 0)) == "")
        #expect(label.accessibilityAttributedString(for: NSRange(location: 0, length: 1))?.string == "a")
    }

    @Test func accessibilityRangesOutsideTheTextAreNil() {
        let outside = [
            NSRange(location: 0, length: 5), NSRange(location: 4, length: 1), NSRange(location: 5, length: 0),
            NSRange(location: NSNotFound, length: 0), NSRange(location: NSNotFound, length: 1),
            NSRange(location: 1, length: Int.max),
        ]
        for range in outside {
            #expect(label.accessibilityString(for: range) == nil, "\(range)")
            #expect(label.accessibilityAttributedString(for: range) == nil, "\(range)")
        }
    }

    @Test func styledFillsOnlyTheRunsWithoutAFontOrColor() {
        let content = NSMutableAttributedString(string: "plain bold")
        let bold = NSFont.boldSystemFont(ofSize: 20)
        content.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))
        let base = NSFont.systemFont(ofSize: 11)
        let styled = LabelText.styled(content, font: base, color: NSColor.red)
        #expect(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == base)
        #expect(styled.attribute(.font, at: 6, effectiveRange: nil) as? NSFont == bold)
        #expect(styled.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor == NSColor.red)
        #expect(LabelText.styled(NSAttributedString(string: ""), font: base, color: NSColor.red).length == 0)
    }

    @Test func lineMetricsOfARangePastTheTextAreNil() {
        let text = NSAttributedString(string: "ab", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(LabelText.WholePointLines.metrics(of: text, in: NSRange(location: 0, length: 2)) != nil)
        #expect(LabelText.WholePointLines.metrics(of: text, in: NSRange(location: 10, length: 3)) == nil)
    }
}
