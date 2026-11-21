// cmux: the message box's Edit > Undo stays in step with its text (cmux #48500). Not a vendored file.
//
// NSTextView's typing undo (`NSUndoTyping`) remembers character ranges of the field's text storage.
// A change to that storage that registers no undo of its own moves the text under those ranges, and
// a later Cmd+Z or Cmd+Shift+Z reads past the end: AppKit throws NSRangeException from
// `-[NSTextStorage(NSUndo) _undoRedoAttributedSubstringFromRange:]` and the app ends (nightly
// 4475022227601, 2026-11-20). The draft rebuilt the field that way whenever an attachment came in or
// left, and the field deleted the picture an undo had just put back. So every change to the field's
// text is one of two things:
//   - an edit on the undo stack (the person's own, or `takeDraftText(_:undoable: true)` for a
//     picture that came in), or
//   - a change that takes the field's entries off the stack (`forgetUndo`).
import AppKit

extension FieldTextView {
    /// Puts BUILT (the draft's text with its attachments) in the field. When the text changes,
    /// UNDOABLE makes the change one undo step (a picture that came in: Cmd+Z takes it out, Cmd+Shift+Z
    /// puts it back); otherwise the field's entries leave the undo stack, whose ranges no longer fit
    /// the text. The same text (an attachment's picture or upload changed) leaves the stack alone.
    func takeDraftText(_ built: NSAttributedString, undoable: Bool) {
        guard let storage = textStorage else { return }
        let old = storage.string as NSString
        guard !old.isEqual(to: built.string) else { storage.setAttributedString(built); return }
        let change = Self.change(from: old, to: built.string as NSString)
        let replaced = storage.attributedSubstring(from: change.old)
        storage.setAttributedString(built)
        breakUndoCoalescing()
        guard undoable, allowsUndo, let undo = undoManager else { forgetUndo(); return }
        let open = undo.groupingLevel == 0
        if open { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self, selector: #selector(undoDraftStep(_:)), object: DraftUndoStep(range: change.new, text: replaced))
        if open { undo.endUndoGrouping() }
    }

    /// Takes the field's entries (typing and `takeDraftText`'s) off the undo stack: its text changed
    /// without them.
    func forgetUndo() {
        breakUndoCoalescing()
        guard let undo = undoManager else { return }
        undo.removeAllActions(withTarget: self)
        if let storage = textStorage { undo.removeAllActions(withTarget: storage) }
    }

    /// The undo (and the redo) of a `takeDraftText` step: its text goes back over its range, and
    /// the step that puts back what was there goes on the other stack. The step registers that
    /// inverse itself: while Edit > Undo runs it, NSTextView's `shouldChangeText` registered a redo
    /// entry with the range the edit replaced, not the range of its text after the edit, and the
    /// Redo read past the end of the field (NSRangeException in
    /// `-[NSUndoReplaceCharacters undoRedo:]`, a1318). The draft follows through `textDidChange`.
    @objc private func undoDraftStep(_ step: DraftUndoStep) {
        let range = step.range, text = step.text
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { forgetUndo(); return }
        let current = storage.attributedSubstring(from: range)
        breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: text)
        let inverse = DraftUndoStep(range: NSRange(location: range.location, length: text.length), text: current)
        undoManager?.registerUndo(withTarget: self, selector: #selector(undoDraftStep(_:)), object: inverse)
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        didChangeText()
    }

    /// The one range OLD and NEW differ in (UTF-16; the common start and end left out, a surrogate
    /// pair kept whole): `old` in OLD, `new` in NEW.
    static func change(from old: NSString, to new: NSString) -> (old: NSRange, new: NSRange) {
        let shorter = min(old.length, new.length)
        var head = 0
        while head < shorter, old.character(at: head) == new.character(at: head) { head += 1 }
        if head > 0, UTF16.isLeadSurrogate(old.character(at: head - 1)) { head -= 1 }
        var tail = 0
        while tail < shorter - head, old.character(at: old.length - 1 - tail) == new.character(at: new.length - 1 - tail) { tail += 1 }
        if tail > 0, UTF16.isTrailSurrogate(old.character(at: old.length - tail)) { tail -= 1 }
        return (NSRange(location: head, length: old.length - head - tail), NSRange(location: head, length: new.length - head - tail))
    }
}

/// One `takeDraftText` undo step: the text that went, and where its replacement is.
final class DraftUndoStep: NSObject {
    let range: NSRange
    let text: NSAttributedString
    init(range: NSRange, text: NSAttributedString) {
        self.range = range
        self.text = text
    }
}

extension ComposeView {
    /// Whether the draft going from the field's attachments CHIPS to NOW only took new ones in (a
    /// paste or a drop): the field's rebuild for it is an undo step. Anything else that rebuilds the
    /// field's text (a send, another chat's draft, a removal the host made) is not.
    static func onlyArrived(_ now: [Attachment], over chips: [Attachment]) -> Bool {
        let had = Set(chips.map(\.id)), has = Set(now.map(\.id))
        return has.isStrictSuperset(of: had)
    }
}
