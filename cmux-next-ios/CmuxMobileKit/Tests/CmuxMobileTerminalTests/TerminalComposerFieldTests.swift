#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// User report 2026-11-12 (iPhone): the terminal's "Message" composer ran a
/// multi-line draft below its rounded field and had no autocorrection
/// ("hm no autocorrect i guess thats maybe ok"). The composer grows upward to
/// `ComposerFieldHeight.defaultMaxLines`, then scrolls inside, and takes
/// autocorrection and spell checking; the terminal's own key input does not.
@MainActor
@Suite struct TerminalComposerFieldTests {
    static func field(_ lines: Int) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.font = .preferredFont(forTextStyle: .body)
        let inset = TerminalDockMetrics.textInset
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
        #expect(caret.minY >= visible.minY - 0.5 && caret.maxY <= visible.maxY + 0.5, "caret \(caret) in \(visible)")
    }

    @Test func messageComposerAutocorrectsButKeepsShellQuotesStraight() {
        let traits = ComposerTextTraits(of: ComposerUITextView())
        #expect(traits == .terminalMessage)
        #expect(traits.autocorrection == .yes)
        #expect(traits.spellChecking == .yes)
        #expect(traits.autocapitalization == .sentences)
        #expect(traits.smartQuotes == .no)
        #expect(traits.smartDashes == .no)
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
