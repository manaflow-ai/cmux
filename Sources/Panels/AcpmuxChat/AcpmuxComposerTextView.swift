import AppKit

/// The composer's text view: Return sends, Shift-Return inserts a newline, Escape
/// cancels the running turn. Marked (IME) text never triggers a send.
final class AcpmuxComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: (() -> Void)?

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
        case #selector(cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onHeightChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onHeightChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onHeightChange?()
    }

    /// Whether the placeholder should show: no text and no marked (IME) text.
    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    /// Where the first glyph of the text starts, in this view's coordinates.
    var textOrigin: CGPoint {
        CGPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
    }

    /// The bounds of the laid-out glyphs in this view's coordinates, the send morph's start.
    var glyphBounds: CGRect {
        guard let layoutManager, let textContainer else { return CGRect(origin: textOrigin, size: .zero) }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(for: textContainer)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return bounds.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Height of the current text, for auto-growth.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height) + 2 * textContainerInset.height
    }
}
