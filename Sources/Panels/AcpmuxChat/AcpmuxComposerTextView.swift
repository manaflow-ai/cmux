import AppKit

/// The composer's text view: Return sends, Shift-Return inserts a newline, Escape
/// cancels the running turn. Marked (IME) text never triggers a send.
final class AcpmuxComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var placeholderColor: NSColor = .placeholderTextColor

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
        needsDisplay = true
        onHeightChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: placeholderColor,
        ])
    }

    /// Height of the current text, for auto-growth.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height) + 2 * textContainerInset.height
    }
}
