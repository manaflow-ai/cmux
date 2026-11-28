#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// User report 2026-11-12 (iPhone): the terminal's "Message" composer ran a
/// multi-line draft below its rounded field ("whoa it go down"). The composer
/// grows upward to `ComposerFieldHeight.defaultMaxLines`, then scrolls inside.
/// Its text traits stay terminal-safe (SPEC M2): a draft is pasted into the
/// program, so no autocorrection, capitals or smart punctuation.
@MainActor
@Suite struct TerminalComposerFieldTests {
    static func field(_ lines: Int) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = (1...lines).map { "echo \($0)" }.joined(separator: "\n")
        view.frame = CGRect(origin: .zero, size: view.fittingSize(proposedWidth: 280))
        view.layoutIfNeeded()
        return view
    }

    /// Leo, 2026-11-23: typing in a long draft lagged by seconds. SwiftUI asks the field's size
    /// at several widths, again in every pass; each answer is the settled height, measuring
    /// nothing, and a key typed past `maxLines` settles without laying out any text.
    @Test func sizeQuestionsAndTypingPastTheCapMeasureNothing() {
        final class Delegate: NSObject, UITextViewDelegate {
            var changes = 0
            func textViewDidChange(_ textView: UITextView) {
                changes += 1
                (textView as? ComposerReturnTextView)?.settleAfterEdit()
            }
        }
        let view = Self.field(40)
        let delegate = Delegate()
        view.delegate = delegate
        let capped = view.fittingSize(proposedWidth: 280).height
        #expect(capped == Self.field(ComposerTextView.maxLines).bounds.height)
        #if DEBUG
        let units = ComposerReturnTextView.measuredUnits
        for width in [0, 120, 280, 1_000, .infinity] as [CGFloat] {
            #expect(view.fittingSize(proposedWidth: width).height == capped)
        }
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        for key in "typing more" { view.insertText(String(key)) }
        if delegate.changes > 0 { #expect(ComposerReturnTextView.measuredUnits == units) }
        #endif
        // A new text (sent, or cleared) measures again: one line.
        view.text = "echo 1"
        #expect(view.fittingSize(proposedWidth: 280).height == Self.field(1).bounds.height)
    }

    /// The other side of the cap shortcut: one long line past the cap at the field's width may
    /// fit a wider width, so that question is still measured (ComposerRowLayout's one-row or
    /// two-row choice; the offline-send hang, #57970).
    @Test func aWiderWidthStillMeasuresOneLongLinePastTheCap() {
        let view = ComposerUITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = Array(repeating: "word", count: 60).joined(separator: " ")
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 400)
        let capped = view.fittingSize(proposedWidth: nil).height
        #expect(capped == Self.field(ComposerTextView.maxLines).bounds.height)
        #expect(view.fittingSize(proposedWidth: 60).height == capped, "narrower wraps no less")
        #expect(view.fittingSize(proposedWidth: 1_000).height < capped, "a wider width can fit it in fewer lines")
    }

    @Test func growsToMaxLinesThenScrollsWithTheCaretInside() {
        let maxLines = ComposerTextView.maxLines
        // The agent chat's six (Leo, 2026-11-23: "composer growth in terminal view on ios is most certainly too high").
        #expect(maxLines == 6)
        let heights = (1...17).map { Self.field($0).bounds.height }
        for index in 1..<maxLines { #expect(heights[index] > heights[index - 1]) }
        for index in maxLines..<heights.count { #expect(heights[index] == heights[maxLines - 1]) }
        let tall = Self.field(17)
        tall.selectedRange = NSRange(location: (tall.text as NSString).length, length: 0)
        tall.followCaret()
        tall.layoutIfNeeded()
        let caret = tall.caretRect(for: tall.endOfDocument)
        let visible = CGRect(origin: tall.contentOffset, size: tall.bounds.size)
        // The caret overhangs its line by about a point on each side.
        #expect(caret.minY >= visible.minY - 2 && caret.maxY <= visible.maxY + 2, "caret \(caret) in \(visible)")
        // Typing at the end shows the field's bottom inset under the last
        // line, as at rest, not the line flush against the field's edge.
        #expect(abs(visible.maxY - tall.contentSize.height) < 0.5, "scrolled to the end: \(visible) of \(tall.contentSize)")
        #expect(tall.textContainerInset == .zero)
    }

    @Test func terminalKeyInputStaysRaw() {
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        #expect(surface.autocorrectionType == .no)
        #expect(surface.spellCheckingType == .no)
        #expect(surface.autocapitalizationType == UITextAutocapitalizationType.none)
        #expect(surface.smartQuotesType == .no)
        #expect(surface.smartDashesType == .no)
    }
}
#endif
