import AppKit

/// The command palette's borderless search field; key events go to
/// `onHandleKeyEvent` before AppKit handles them.
final class CommandPaletteNativeTextField: NSTextField {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
