public import AppKit

/// Single-line `NSTextField` subclass backing the command-palette search field.
///
/// Routes `keyDown`/`performKeyEquivalent` through an injected `onHandleKeyEvent`
/// closure unless the field editor has marked (in-progress IME) text, in which
/// case AppKit's default handling runs so composition is never interrupted.
public final class CommandPaletteNativeTextField: NSTextField {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

    override public init(frame frameRect: NSRect) {
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

    override public func keyDown(with event: NSEvent) {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
