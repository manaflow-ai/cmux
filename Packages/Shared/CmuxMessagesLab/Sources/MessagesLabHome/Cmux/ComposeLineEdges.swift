// cmux: Ctrl+A and Ctrl+E in Home's message box stay on the caret's text line when pictures are in
// the text (Lawrence 2026-10-28: "ctrl+a/ctrl+e should go to start and end of line; image is
// interfering with it"). Not a vendored file.
import AppKit

extension ChatController {
    /// The field's paragraph-edge commands (Ctrl+A, Ctrl+E, and with Shift) with a picture in the
    /// text. A picture is a block on its own line (`ComposeInlineAttachment`), but AppKit reads the
    /// text before and after it as one paragraph, so Ctrl+A under a picture went above it. Here a
    /// picture ends a line as a line break does. Without a picture in the text, AppKit keeps the keys.
    /// - Returns: True when the command was handled here.
    func handlesLineEdgeCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText(), let storage = textView.textStorage,
              (storage.string as NSString).range(of: "\u{FFFC}").location != NSNotFound else { return false }
        let sel = textView.selectedRange()
        let target: NSRange
        switch selector {
        case #selector(NSResponder.moveToBeginningOfParagraph(_:)):
            target = NSRange(location: lineStart(storage, sel.location), length: 0)
        case #selector(NSResponder.moveToEndOfParagraph(_:)):
            target = NSRange(location: lineEnd(storage, NSMaxRange(sel)), length: 0)
        case #selector(NSResponder.moveToBeginningOfParagraphAndModifySelection(_:)):
            let start = lineStart(storage, sel.location)
            target = NSRange(location: start, length: NSMaxRange(sel) - start)
        case #selector(NSResponder.moveToEndOfParagraphAndModifySelection(_:)):
            target = NSRange(location: sel.location, length: lineEnd(storage, NSMaxRange(sel)) - sel.location)
        default:
            return false
        }
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        return true
    }
}

/// Whether the character at `i` ends a line: a line break or a placed picture.
private func endsLine(_ s: NSAttributedString, _ ns: NSString, _ i: Int) -> Bool {
    switch ns.character(at: i) {
    case 0x0A, 0x0D, 0x2028, 0x2029: return true
    case 0xFFFC: return s.attribute(.attachment, at: i, effectiveRange: nil) is ComposeInlineAttachment
    default: return false
    }
}

/// The start of the text line holding `index`: just after the line break or picture before it.
private func lineStart(_ s: NSAttributedString, _ index: Int) -> Int {
    let ns = s.string as NSString
    var i = min(max(0, index), ns.length)
    while i > 0, !endsLine(s, ns, i - 1) { i -= 1 }
    return i
}

/// The end of the text line holding `index`: just before the line break or picture after it.
private func lineEnd(_ s: NSAttributedString, _ index: Int) -> Int {
    let ns = s.string as NSString
    var i = min(max(0, index), ns.length)
    while i < ns.length, !endsLine(s, ns, i) { i += 1 }
    return i
}
