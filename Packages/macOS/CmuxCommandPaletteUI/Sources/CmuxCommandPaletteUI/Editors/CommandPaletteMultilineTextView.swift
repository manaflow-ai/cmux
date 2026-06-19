public import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// Multiline `NSTextView` subclass backing the command-palette workspace
/// description editor.
///
/// Forwards key events through `onHandleKeyEvent` (skipping handling while IME
/// composition is active), reports first-responder acquisition through
/// `onDidBecomeFirstResponder`, and emits DEBUG traces around the AppKit
/// text-editing overrides used to diagnose newline/IME behavior.
public final class CommandPaletteMultilineTextView: NSTextView {
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    var onDidBecomeFirstResponder: (() -> Void)?

    override public func flagsChanged(with event: NSEvent) {
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.flagsChanged " +
            "\((event).commandPaletteEventDebugSummary)"
        )
#endif
        super.flagsChanged(with: event)
    }

    override public func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.textView.becomeFirstResponder success=\(becameFirstResponder ? 1 : 0) " +
            "window={\((window).commandPaletteWindowDebugSummary)} " +
            "fr=\((window?.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        if becameFirstResponder {
            onDidBecomeFirstResponder?()
        }
        return becameFirstResponder
    }

    override public func keyDown(with event: NSEvent) {
        if hasMarkedText() {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.keyDown markedText=1 " +
                "\((event).commandPaletteEventDebugSummary)"
            )
#endif
            super.keyDown(with: event)
            return
        }
        let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.keyDown handled=\(handled ? 1 : 0) " +
            "\((event).commandPaletteEventDebugSummary)"
        )
#endif
        if handled {
            return
        }
        super.keyDown(with: event)
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if hasMarkedText() {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.performKeyEquivalent markedText=1 " +
                "\((event).commandPaletteEventDebugSummary)"
            )
#endif
            return super.performKeyEquivalent(with: event)
        }
        let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.performKeyEquivalent handled=\(handled ? 1 : 0) " +
            "\((event).commandPaletteEventDebugSummary)"
        )
#endif
        if handled {
            return true
        }
        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.performKeyEquivalent superResult=\(result ? 1 : 0) " +
            "\((event).commandPaletteEventDebugSummary)"
        )
#endif
        return result
    }

    override public func doCommand(by commandSelector: Selector) {
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.doCommand selector=\(NSStringFromSelector(commandSelector)) " +
            "len=\((string as NSString).length) " +
            "sel=\(selectedRange().location):\(selectedRange().length)"
        )
#endif
        super.doCommand(by: commandSelector)
    }

    override public func insertNewline(_ sender: Any?) {
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.insertNewline " +
            "len=\((string as NSString).length) " +
            "sel=\(selectedRange().location):\(selectedRange().length)"
        )
#endif
        super.insertNewline(sender)
    }

    override public func insertLineBreak(_ sender: Any?) {
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.insertLineBreak " +
            "len=\((string as NSString).length) " +
            "sel=\(selectedRange().location):\(selectedRange().length)"
        )
#endif
        super.insertLineBreak(sender)
    }

    override public func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.insertNewlineIgnoringFieldEditor " +
            "len=\((string as NSString).length) " +
            "sel=\(selectedRange().location):\(selectedRange().length)"
        )
#endif
        super.insertNewlineIgnoringFieldEditor(sender)
    }
}
