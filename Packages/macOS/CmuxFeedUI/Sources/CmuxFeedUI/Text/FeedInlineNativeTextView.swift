import AppKit
#if DEBUG
import os
#endif

/// The `NSTextView` that backs the inline Feed reply/answer field.
///
/// It owns first-responder bookkeeping for the single active inline editor
/// (so the app can blur it imperatively), routes Escape to `onEscape`, and
/// submits on a bare Return/Enter (no modifiers, no marked IME text) via
/// `onSubmit`. Adopting `FeedKeyboardFocusResponder` lets the app's window
/// focus controller recognize that keyboard focus lives in the Feed sidebar.
final class FeedInlineNativeTextView: NSTextView, FeedKeyboardFocusResponder {
    private static weak var activeEditor: FeedInlineNativeTextView?

#if DEBUG
    private static let log = Logger(subsystem: "com.cmux.feed", category: "InlineEditor")

    private static func responderSummary(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }
#endif

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    static func blurActiveEditor() {
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
        Self.log.debug("feed.editor.blurActive fr=\(Self.responderSummary(window.firstResponder), privacy: .public)")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        Self.log.debug("feed.editor.mouseDown frBefore=\(Self.responderSummary(self.window?.firstResponder), privacy: .public)")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            Self.log.debug("feed.editor.escape fr=\(Self.responderSummary(self.window?.firstResponder), privacy: .public)")
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
        Self.log.debug("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0, privacy: .public) fr=\(Self.responderSummary(self.window?.firstResponder), privacy: .public)")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        Self.log.debug("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0, privacy: .public) fr=\(Self.responderSummary(self.window?.firstResponder), privacy: .public)")
#endif
        return didResignFirstResponder
    }
}
