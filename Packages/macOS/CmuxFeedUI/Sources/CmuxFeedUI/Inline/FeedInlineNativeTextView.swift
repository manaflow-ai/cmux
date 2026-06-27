public import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// AppKit text view backing the feed inline reply/answer editor.
///
/// Tracks the process-wide active editor so focus can be relinquished from
/// elsewhere, submits on a bare Return/Enter (deferring to marked-text/IME
/// composition), cancels on Escape, and reports activation through the
/// ``onActivate``/``onEscape``/``onSubmit`` closures the representable wires in.
///
/// The right-sidebar focus router treats this view as a feed focus owner via a
/// `FeedKeyboardFocusResponder` conformance; that marker lives in `CmuxSidebar`,
/// so the app target declares the conformance at the composition root rather
/// than this UI package reaching up into the sidebar module.
public final class FeedInlineNativeTextView: NSTextView {
    private static weak var activeEditor: FeedInlineNativeTextView?

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    /// Resigns first responder from the currently active feed inline editor, if
    /// any is still keyed in its window.
    public static func blurActiveEditor() {
        guard let activeEditor else { return }
        guard let window = activeEditor.window else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
        guard window.firstResponder === activeEditor else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
#if DEBUG
        logDebugEvent("feed.editor.blurActive fr=\(window.firstResponder.feedInlineResponderDebugSummary)")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        logDebugEvent("feed.editor.mouseDown frBefore=\(window?.firstResponder.feedInlineResponderDebugSummary)")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            logDebugEvent("feed.editor.escape fr=\(window?.firstResponder.feedInlineResponderDebugSummary)")
#endif
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldSubmit = (event.keyCode == 36 || event.keyCode == 76)
            && normalizedFlags.intersection([.shift, .option, .command, .control]).isEmpty
        if shouldSubmit, !hasMarkedText(), let onSubmit {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            Self.activeEditor = self
            onActivate?()
        }
#if DEBUG
        logDebugEvent("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0) fr=\(window?.firstResponder.feedInlineResponderDebugSummary)")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        logDebugEvent("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0) fr=\(window?.firstResponder.feedInlineResponderDebugSummary)")
#endif
        return didResignFirstResponder
    }
}
