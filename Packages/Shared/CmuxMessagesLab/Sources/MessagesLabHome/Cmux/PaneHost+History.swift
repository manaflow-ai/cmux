// cmux: Up and Down recall sent messages in Home's message box, from the box
// and from anywhere else in Home (Lawrence 2026-10-19: "Up arrow ... We need
// to handle unfocus as well so that, like it is history"). Not a vendored file.
import AppKit

extension ChatController {
    /// The field's `moveUp:` / `moveDown:` (plain Up and Down; Shift, Option
    /// and Command arrows are other selectors and keep AppKit's meaning).
    ///
    /// The key rule: while the field shows a recalled entry the person has not
    /// edited, Up and Down step through the history wherever the caret is.
    /// Otherwise Up recalls only with the caret on the first visual line, and
    /// Down does nothing here: in a multi-line draft the arrows move the caret
    /// as usual. IME composition keeps its arrows (AppKit sends them to the
    /// input method before any command).
    /// - Returns: True when the history took the command.
    func handlesHistoryCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        guard picker == nil, !textView.hasMarkedText(), let field = textView as? FieldTextView else { return false }
        let direction: ComposerHistory.Direction
        switch selector {
        case #selector(NSResponder.moveUp(_:)): direction = .older
        case #selector(NSResponder.moveDown(_:)): direction = .newer
        default: return false
        }
        // A browse owns the arrows: past the oldest entry Up changes nothing (no caret jump to the start).
        if composerHistory.shown == field.string {
            stepHistory(direction, in: field)
            return true
        }
        guard direction == .older, field.caretLine.first else { return false }
        return stepHistory(direction, in: field)
    }

    /// Up or Down while Home has the keyboard but its field does not (the
    /// transcript, the pane, a header button, nothing after a pane focus):
    /// the field takes the keyboard, and Up recalls the newest sent message
    /// (or the next older one while a browse runs) whatever the caret's line;
    /// Down steps newer only while a browse runs.
    /// - Parameter direction: Which arrow.
    /// - Returns: True when the field took the key (always, once Home shows a field).
    @discardableResult
    func recallHistoryFromOutside(_ direction: ComposerHistory.Direction) -> Bool {
        guard let field = demo?.compose.textView.view else { return false }
        focusComposeForTyping()
        if direction == .older || composerHistory.isBrowsing { stepHistory(direction, in: field) }
        return true
    }

    /// Whether an Up or Down from `responder` belongs to the field's history:
    /// not from a text input (it has its own caret) and not from a transcript
    /// text selection (the person holds it to copy). Home's transcript has no
    /// arrow-key scrolling, so nothing else in the pane loses its arrows.
    func historyTakesArrowKeys(from responder: NSResponder?) -> Bool {
        if responder is NSText || responder is NSTextField { return false }
        if let doc = responder as? TranscriptDocumentView, doc === host.scrollView.document,
           selection.dragging || !selection.isEmpty {
            return false
        }
        return true
    }

    /// One history step into `field`; false when there is nothing to step to.
    @discardableResult
    private func stepHistory(_ direction: ComposerHistory.Direction, in field: FieldTextView) -> Bool {
        guard let state = store?.state,
              let text = composerHistory.step(direction, current: field.string, entries: ComposerHistory.entries(in: state)) else {
            return false
        }
        field.replaceAllText(with: text)
        return true
    }
}

extension FieldTextView {
    /// Replaces the whole text as one undoable edit and puts the caret at the
    /// end; the delegate's `textDidChange` runs (the draft follows).
    func replaceAllText(with text: String) {
        let all = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: all, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Whether the caret (a selection's start for `first`, its end for `last`)
    /// sits on the first and on the last visual line, wrapped lines counted.
    var caretLine: (first: Bool, last: Bool) {
        let ns = string as NSString
        let sel = selectedRange()
        guard ns.length > 0 else { return (true, true) }
        if let start = lineY(at: 0), let end = lineY(at: ns.length),
           let head = lineY(at: sel.location), let tail = lineY(at: NSMaxRange(sel)) {
            return (abs(head - start) < 1, abs(tail - end) < 1)
        }
        // No layout yet: hard line breaks only.
        let before = ns.substring(to: sel.location), after = ns.substring(from: NSMaxRange(sel))
        return (!before.contains("\n"), !after.contains("\n"))
    }

    /// The vertical middle of the caret's line at UTF-16 offset `index`.
    private func lineY(at index: Int) -> CGFloat? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: index) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        var y: CGFloat?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
            y = rect.midY
            return false
        }
        return y
    }
}
