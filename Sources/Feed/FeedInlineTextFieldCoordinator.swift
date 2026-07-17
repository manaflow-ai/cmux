import AppKit
import Foundation

@MainActor
final class FeedInlineTextFieldCoordinator: NSObject, NSTextViewDelegate {
    var parent: FeedInlineTextField
    var isProgrammaticMutation = false
    weak var view: FeedInlineTextEditorView?
    var lastAppliedFocusRequest: Int?

    init(parent: FeedInlineTextField) {
        self.parent = parent
        self.lastAppliedFocusRequest = parent.focusRequest
    }

    func activateField() {
#if DEBUG
        dlog("feed.editor.activateField")
#endif
        parent.onFocus()
    }

    func blurField() {
        guard let view, let window = view.window, window.firstResponder === view.textView else {
            return
        }
#if DEBUG
        dlog("feed.editor.blurField frBefore=\(feedDebugResponderSummary(window.firstResponder))")
#endif
        guard parent.placement.usesRightSidebarFocusCoordinator else {
            window.makeFirstResponder(nil)
            return
        }
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .feed,
            focusFirstItem: false,
            preferredWindow: window
        ) != true {
            window.makeFirstResponder(nil)
        }
    }

    func textDidBeginEditing(_ notification: Notification) {
        activateField()
    }

    func textDidChange(_ notification: Notification) {
        guard !isProgrammaticMutation else { return }
        guard let textView = notification.object as? NSTextView else { return }
        parent.text = textView.string
        view?.refreshMetrics()
    }

    func textDidEndEditing(_ notification: Notification) {
        if !isProgrammaticMutation, let textView = notification.object as? NSTextView {
            parent.text = textView.string
        }
        guard let window = view?.window else {
            parent.onBlur()
            return
        }
        let responder = window.firstResponder
        if !(responder is FeedKeyboardFocusView) && !(responder is FeedInlineNativeTextView) {
            parent.onBlur()
        }
    }

}
