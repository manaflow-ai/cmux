import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Records the `UITextInputDelegate` callbacks UIKit's modern document-driven
/// backspace auto-repeat depends on, so a test can assert the input view fires
/// them on each empty-buffer delete (the *re-arm* that keeps the repeat going).
private final class RecordingInputDelegate: NSObject, UITextInputDelegate {
    private(set) var textWillChangeCount = 0
    private(set) var textDidChangeCount = 0

    func selectionWillChange(_ textInput: (any UITextInput)?) {}
    func selectionDidChange(_ textInput: (any UITextInput)?) {}
    func textWillChange(_ textInput: (any UITextInput)?) { textWillChangeCount += 1 }
    func textDidChange(_ textInput: (any UITextInput)?) { textDidChangeCount += 1 }
}

/// Behavioral coverage for the iOS terminal input view's hold-to-repeat
/// backspace mechanism.
///
/// These tests deliberately do **not** try to assert "the keyboard fired
/// `deleteBackward` N times" — UIKit's keyboard repeat timer does not exist in a
/// headless/unit context, so counting our own loop calls would be a tautology
/// that passes on the broken code too. Instead they assert the *mechanism* that
/// the three prior fixes lacked and that drives UIKit's repeat: a one-character
/// zero-width virtual document with the caret at its end, re-armed via
/// `inputDelegate.textWillChange`/`textDidChange` on every empty-buffer delete.
///
/// - The `inputDelegate` re-arm discriminates this fix from PR #5573, which also
///   forced `hasText == true` (so asserting `hasText` alone proves nothing) but
///   never notified UIKit of a document change, so the repeat still died.
/// - The offset-bearing anchor document (`endOfDocument == 1`, `text(in:)`
///   returns the zero-width char) discriminates this fix from the prior
///   documentless attempt, whose identity-only range sentinels always reported
///   length 0, so UIKit saw "nothing to delete".
@MainActor
@Suite("TerminalInputTextView hold-to-repeat backspace")
struct TerminalInputDeleteRepeatTests {
    /// The two zero-width characters the anchor alternates between (vvterm's
    /// `\u{200B}` and `\u{2060}`).
    private static let anchorChars: Set<String> = ["\u{200B}", "\u{2060}"]

    private func makeView(delegate: RecordingInputDelegate) -> TerminalInputTextView {
        let view = TerminalInputTextView()
        view.inputDelegate = delegate
        return view
    }

    @Test("hasText is always true so the keyboard keeps the delete key repeating")
    func hasTextIsAlwaysTrue() {
        let view = TerminalInputTextView()
        #expect(view.hasText)
    }

    @Test("with no composition the view presents a one-character zero-width anchor document")
    func presentsOneCharacterAnchorDocument() {
        let view = TerminalInputTextView()
        // No marked text: the virtual document is the delete-repeat anchor, one
        // zero-width character long with the caret at the end. An identity-only
        // sentinel (the prior documentless attempt) would report length 0 here.
        let length = view.offset(from: view.beginningOfDocument, to: view.endOfDocument)
        #expect(length == 1)

        guard let selected = view.selectedTextRange else {
            Issue.record("expected a selected text range for the caret")
            return
        }
        // Caret collapsed at the end of the one-character document.
        #expect(view.offset(from: view.beginningOfDocument, to: selected.start) == 1)
        #expect(selected.isEmpty)

        guard let full = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) else {
            Issue.record("expected a full document range")
            return
        }
        let anchor = view.text(in: full)
        #expect(anchor != nil)
        #expect(Self.anchorChars.contains(anchor ?? ""))
    }

    @Test("an empty-buffer delete sends DEL and re-arms the anchor via inputDelegate")
    func emptyBufferDeleteRoutesBackspaceAndReArms() {
        let delegate = RecordingInputDelegate()
        let view = makeView(delegate: delegate)

        var backspaceCount = 0
        var textCount = 0
        view.onBackspace = { backspaceCount += 1 }
        view.onText = { _ in textCount += 1 }

        view.deleteBackward()

        // The DEL byte must reach the terminal exactly once...
        #expect(backspaceCount == 1)
        #expect(textCount == 0)
        // ...and the anchor must be re-armed by notifying UIKit the (still
        // one-character) document changed. This textWillChange/textDidChange pair
        // is the piece PR #5573 lacked, which is why its forced hasText==true was
        // not enough to keep the repeat going.
        #expect(delegate.textWillChangeCount == 1)
        #expect(delegate.textDidChangeCount == 1)
    }

    @Test("consecutive empty-buffer deletes toggle the anchor character so the document content changes")
    func consecutiveDeletesAlternateAnchorCharacter() {
        let view = TerminalInputTextView()

        func currentAnchor() -> String? {
            guard let full = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) else {
                return nil
            }
            return view.text(in: full)
        }

        let first = currentAnchor()
        view.deleteBackward()
        let second = currentAnchor()
        view.deleteBackward()
        let third = currentAnchor()

        #expect(first != nil)
        #expect(second != nil)
        #expect(third != nil)
        // Each delete flips the anchor char, so the virtual document's *contents*
        // change every time. That content change (not just hasText) is what makes
        // UIKit re-read the document and keep repeating.
        #expect(first != second)
        #expect(second != third)
        #expect(first == third)
        #expect(Self.anchorChars.contains(first ?? ""))
        #expect(Self.anchorChars.contains(second ?? ""))
    }

    @Test("repeated empty-buffer deletes keep routing DEL (the routing is stateless, not one-shot)")
    func repeatedDeletesKeepRoutingDEL() {
        let view = TerminalInputTextView()
        var backspaceCount = 0
        view.onBackspace = { backspaceCount += 1 }

        // Simulate the keyboard's repeat timer calling deleteBackward repeatedly.
        // This does not prove the timer fires (only a live keyboard can); it
        // proves that when it does fire, each call routes a DEL rather than the
        // routing going one-shot the way the prior UITextView path did (it fell
        // into super.deleteBackward() and swallowed subsequent deletes).
        for _ in 0..<5 {
            view.deleteBackward()
        }
        #expect(backspaceCount == 5)
    }

    @Test("while composing IME text a delete cancels composition and does not send a backspace")
    func deleteDuringCompositionCancelsInsteadOfRoutingBackspace() {
        let delegate = RecordingInputDelegate()
        let view = makeView(delegate: delegate)

        var backspaceCount = 0
        view.onBackspace = { backspaceCount += 1 }

        // Begin an IME composition (e.g. a Korean syllable in progress).
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        #expect(view.markedTextRange != nil)

        view.deleteBackward()

        // Composition is cancelled; nothing is sent to the Mac.
        #expect(backspaceCount == 0)
        #expect(view.markedTextRange == nil)
    }

    @Test("while composing, the virtual document is the marked text, not the anchor")
    func compositionSuppressesTheAnchor() {
        let view = TerminalInputTextView()
        view.setMarkedText("ab", selectedRange: NSRange(location: 2, length: 0))

        guard let marked = view.markedTextRange else {
            Issue.record("expected a marked text range while composing")
            return
        }
        // The exposed document is the marked composition (length 2), so the
        // zero-width anchor is suppressed while the IME is active.
        #expect(view.offset(from: view.beginningOfDocument, to: view.endOfDocument) == 2)
        #expect(view.text(in: marked) == "ab")
    }
}
