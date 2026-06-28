import Foundation
import UIKit

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    // Autocorrect/predictive/smart substitutions are all off: the view forwards
    // each keystroke to the remote terminal and keeps no in-progress word for the
    // keyboard to correct against. Returning these as computed properties (rather
    // than the `UITextView` stored traits the old design used) keeps the keyboard
    // from offering corrections it could never apply.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}

// MARK: - Documentless virtual document + delete-repeat anchor

extension TerminalInputTextView {
    /// Always report that there is text to delete.
    ///
    /// This is the legacy ``UIKeyInput`` gate (borrowed from iSH's
    /// `TerminalView`) for the software keyboard's *hold-to-repeat* backspace. On
    /// a bare ``UIKeyInput`` responder (this view) the keyboard's auto-repeat
    /// timer keeps firing ``deleteBackward()`` only while the first responder
    /// reports `hasText == true`. It is always safe to send a DEL byte to the
    /// remote terminal, so there is no "nothing to delete" state to honor —
    /// return `true` unconditionally.
    ///
    /// Internal byte-routing therefore must *not* key off `hasText` (it is a
    /// constant); ``deleteBackward()`` and the modifier guards key off
    /// ``markedText`` (IME composition) instead.
    var hasText: Bool { true }

    /// Whether the view is currently presenting the zero-width delete-repeat
    /// anchor: there is no IME composition, so the view fabricates a
    /// one-character virtual document with the caret at the end. While this is
    /// true UIKit's modern document-driven repeat path sees a deletable character
    /// to the left of the cursor and keeps firing ``deleteBackward()``. Mirrors
    /// vvterm's `usesDeleteRepeatAnchor`.
    private var usesDeleteRepeatAnchor: Bool { markedText == nil }

    /// The current zero-width anchor character. Toggling between two distinct
    /// zero-width characters on each empty-buffer delete forces the virtual
    /// document's contents to change, which is what re-arms the repeat. (vvterm:
    /// `deleteRepeatAnchorText`.)
    private var deleteRepeatAnchorText: String {
        deleteRepeatAnchorUsesAlternate ? "\u{2060}" : "\u{200B}"
    }

    /// The virtual document UIKit walks: the IME composition while marking,
    /// otherwise the one-character zero-width delete-repeat anchor.
    private var textInputDocument: String {
        usesDeleteRepeatAnchor ? deleteRepeatAnchorText : (markedText ?? "")
    }

    /// UTF-16 length of the virtual ``textInputDocument``.
    private var textInputDocumentLength: Int {
        (textInputDocument as NSString).length
    }

    /// The caret sits at the end of the virtual document (after the anchor char,
    /// or at the end of the marked composition) so there is always something to
    /// its left to delete.
    private var effectiveSelectedRange: NSRange {
        NSRange(location: textInputDocumentLength, length: 0)
    }

    /// Re-arm the delete-repeat anchor after an empty-buffer delete.
    ///
    /// Toggling the anchor char inside `textWillChange`/`textDidChange` brackets
    /// tells UIKit the (still one-character) virtual document changed, so the
    /// keyboard's document-driven repeat timer re-reads it and fires the next
    /// ``deleteBackward()``. Without this the modern repeat path stalls after one
    /// delete even though ``hasText`` stays `true` — this is the refinement the
    /// prior documentless attempt lacked. Mirrors vvterm's
    /// `notifyVirtualDeleteAnchorDidChange`. Internal because ``deleteBackward()``
    /// (in the main view body) calls it on every empty-buffer backspace.
    func notifyVirtualDeleteAnchorDidChange() {
        inputDelegate?.textWillChange(self)
        deleteRepeatAnchorUsesAlternate.toggle()
        inputDelegate?.textDidChange(self)
    }
}

// MARK: - UITextInput (documentless conformance + delete-repeat anchor)

// This view owns no editable document. It implements `UITextInput` to unlock two
// keyboard features a bare `UIKeyInput` view does not get — system dictation (the
// mic key) and IME marked-text composition — and to present vvterm's toggling
// one-character zero-width *delete-repeat anchor* so the software keyboard's
// modern document-driven backspace auto-repeat keeps firing while the key is
// held. Recognized dictation text and committed IME candidates both arrive
// through ``insertText(_:)`` and route to the terminal. UIKit walks the virtual
// document (`textInputDocument`) through the offset-bearing
// ``TerminalInputTextPosition`` / ``TerminalInputTextRange`` types, so positions
// and ranges carry real UTF-16 offsets rather than acting as pure identity
// sentinels — that is what lets the view report a one-character document with the
// caret at the end, the condition the repeat path checks.
extension TerminalInputTextView {
    /// The range covering the active IME composition, or `nil` when not composing
    /// (the `nil` is what suppresses the delete-repeat anchor while marking).
    var markedTextRange: UITextRange? {
        guard let markedText, !markedText.isEmpty else { return nil }
        return TerminalInputTextRange(start: 0, end: (markedText as NSString).length)
    }

    /// The caret/selection UIKit reads: always the collapsed caret at the end of
    /// the virtual document (``effectiveSelectedRange``). The setter is ignored —
    /// this documentless proxy owns no movable selection.
    var selectedTextRange: UITextRange? {
        get {
            let range = effectiveSelectedRange
            return TerminalInputTextRange(start: range.location, end: range.location + range.length)
        }
        set {}
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    /// The start of the virtual document (offset 0).
    var beginningOfDocument: UITextPosition { TerminalInputTextPosition(offset: 0) }
    /// The end of the virtual document (its UTF-16 length).
    var endOfDocument: UITextPosition { TerminalInputTextPosition(offset: textInputDocumentLength) }

    /// The IME hands a candidate string in; hold it as the marked composition so
    /// ``markedTextRange`` reports active composition (which also suppresses the
    /// delete-repeat anchor). Nothing is sent to the terminal until the candidate
    /// commits via ``insertText(_:)`` or ``unmarkText()``.
    ///
    /// Mutating ``markedText`` changes the string the view exposes through
    /// ``text(in:)``/``markedTextRange``, so it is a *text* change in the
    /// ``UITextInputDelegate`` contract: it is bracketed with
    /// `textWillChange`/`textDidChange` (via ``withMarkedTextChange(_:)``) so the
    /// IME and dictation machinery keep their composition state synchronized.
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        TerminalInputDebugLog.log("proxy.setMarkedText len=\((markedText ?? "").count)")
        withMarkedTextChange {
            self.markedText = (markedText?.isEmpty == true) ? nil : markedText
        }
    }

    /// Brackets a mutation of ``markedText`` (or the anchor crossover when
    /// composition ends) with the `UITextInputDelegate` text-change callbacks.
    ///
    /// The marked composition is the only committed text this view exposes, so
    /// any change to it — set by the IME, committed by
    /// ``insertText(_:)``/``unmarkText()``, or canceled by ``deleteBackward()`` —
    /// is a text change UIKit must be told about with
    /// `textWillChange`/`textDidChange`. Selection-only callbacks would leave the
    /// keyboard observing stale composition state.
    func withMarkedTextChange(_ mutate: () -> Void) {
        inputDelegate?.textWillChange(self)
        mutate()
        inputDelegate?.textDidChange(self)
    }

    /// Commit the in-progress IME composition. Forwards the held candidate to the
    /// terminal as one block.
    func unmarkText() {
        guard let composing = markedText else { return }
        withMarkedTextChange { markedText = nil }
        emitCommittedText(composing, source: "unmarkText")
    }

    /// Returns the substring of the virtual document for `range`, clamped to its
    /// bounds. The keyboard reads this to mirror the zero-width delete-repeat
    /// anchor (or the marked composition while an IME is active).
    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalInputTextRange else { return nil }
        let document = textInputDocument as NSString
        let clamped = clampedDocumentRange(range.nsRange, length: document.length)
        guard clamped.length > 0 else { return "" }
        return document.substring(with: clamped)
    }

    /// Commit text delivered through a range replacement.
    ///
    /// Most committed input arrives via ``insertText(_:)``, but some system paths
    /// (text replacement, certain dictation/suggestion commits) deliver it by
    /// replacing ``selectedTextRange`` or ``markedTextRange`` instead. The view
    /// holds no addressable document, so the range itself is ignored, but the
    /// *text* must still reach the terminal — route it through the same commit
    /// path as ``insertText(_:)``. A replacement of the marked region supersedes
    /// the in-progress IME composition, so clear it first. An empty replacement is
    /// a pure deletion of the marked composition (no committed text to send).
    func replace(_ range: UITextRange, withText text: String) {
        TerminalInputDebugLog.log("proxy.replace len=\(text.count)")
        if markedText != nil {
            withMarkedTextChange { markedText = nil }
        }
        guard !text.isEmpty else { return }
        emitCommittedText(text, source: "replace")
    }

    /// Builds a ``TerminalInputTextRange`` spanning two offset-bearing positions.
    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition else { return nil }
        return TerminalInputTextRange(start: from.offset, end: to.offset)
    }

    /// Offsets a position within the virtual document, clamped to its length.
    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalInputTextPosition else { return nil }
        let target = min(max(position.offset + offset, 0), textInputDocumentLength)
        return TerminalInputTextPosition(offset: target)
    }

    /// Directional variant of ``position(from:offset:)``: right/down advance,
    /// left/up retreat, clamped to the virtual document.
    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalInputTextPosition else { return nil }
        let delta = (direction == .right || direction == .down) ? offset : -offset
        let target = min(max(position.offset + delta, 0), textInputDocumentLength)
        return TerminalInputTextPosition(offset: target)
    }

    /// Orders two positions by their UTF-16 offset.
    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let lhs = position as? TerminalInputTextPosition,
              let rhs = other as? TerminalInputTextPosition else { return .orderedSame }
        if lhs.offset < rhs.offset { return .orderedAscending }
        if lhs.offset > rhs.offset { return .orderedDescending }
        return .orderedSame
    }

    /// The signed UTF-16 distance from one position to another.
    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition else { return 0 }
        return to.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { .zero }
    func caretRect(for position: UITextPosition) -> CGRect { .zero }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { nil }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { nil }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    /// Clamps an `NSRange` to `0..<length` so ``text(in:)`` never reads outside
    /// the virtual document's bounds.
    private func clampedDocumentRange(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), max(length - location, 0))
        return NSRange(location: location, length: rangeLength)
    }

    // MARK: Dictation placeholder hooks
    //
    // UIKit calls these when the mic is tapped. Returning a placeholder (an empty
    // token; iSH does the same) is what tells the framework this view accepts
    // dictation; the recognized text then arrives via `insertText`. The remove
    // hook is a no-op because there is no document placeholder to strip.
    func insertDictationResultPlaceholder() -> Any { "" }
    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {}
}
