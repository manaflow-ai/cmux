// cmux: the field's typed text follows the palette. Not a vendored file.
import AppKit

extension FieldTextView {
    /// The typed text, the text the next keystroke inserts and the view's default colour in the
    /// palette's composer text (``Fixture/composeText``). The field was coloured once, when it was
    /// made: a theme or Chat Colors change after that left the draft in the old colour (dark text
    /// on a dark field after a light-to-dark switch). Marked IME text keeps its own attributes.
    func recolorText() {
        let ink = Fixture.composeText
        if textColor != ink { textColor = ink }
        if (typingAttributes[.foregroundColor] as? NSColor) != ink {
            var attributes = typingAttributes
            attributes[.foregroundColor] = ink
            typingAttributes = attributes
        }
        guard !hasMarkedText(), let storage = textStorage, storage.length > 0 else { return }
        let all = NSRange(location: 0, length: storage.length)
        var stale = false
        storage.enumerateAttribute(.foregroundColor, in: all) { value, _, stop in
            if (value as? NSColor) != ink { stale = true; stop.pointee = true }
        }
        guard stale else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: ink, range: all)
        storage.endEditing()
    }
}
