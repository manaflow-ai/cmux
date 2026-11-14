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
        let inset = TerminalDockMetrics.textVerticalInset
        view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.text = (1...lines).map { "echo \($0)" }.joined(separator: "\n")
        view.frame = CGRect(origin: .zero, size: view.fittingSize(proposedWidth: 280))
        view.layoutIfNeeded()
        return view
    }

    @Test func growsToMaxLinesThenScrollsWithTheCaretInside() {
        let maxLines = ComposerTextView.maxLines
        #expect(maxLines == ComposerFieldHeight.defaultMaxLines)
        let heights = (1...12).map { Self.field($0).bounds.height }
        for index in 1..<maxLines { #expect(heights[index] > heights[index - 1]) }
        for index in maxLines..<heights.count { #expect(heights[index] == heights[maxLines - 1]) }
        let tall = Self.field(12)
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
        #expect(tall.textContainerInset.top == TerminalDockMetrics.textVerticalInset)
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
