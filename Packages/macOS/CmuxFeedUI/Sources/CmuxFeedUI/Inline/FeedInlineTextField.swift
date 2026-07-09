public import AppKit
public import SwiftUI
#if DEBUG
internal import CMUXDebugLog
#endif

/// SwiftUI wrapper exposing the feed inline reply/answer editor.
///
/// Binds text and focus, measures its own height, submits on a bare
/// Return/Enter, and cancels on Escape. The editor never reaches into app
/// state directly: relinquishing focus to the surrounding feed host and
/// recognizing the feed focus host responder are supplied by the
/// ``focusFeedHost`` and ``isFeedFocusHostResponder`` closures, which the app
/// composition root wires to the right-sidebar focus system.
public struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String

    let focusRequest: Int?
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: (() -> Void)?
    let focusFeedHost: (NSWindow) -> Bool
    let isFeedFocusHostResponder: (NSResponder?) -> Bool

    /// Creates the feed inline editor.
    /// - Parameters:
    ///   - text: Two-way binding to the editor's text.
    ///   - focusRequest: Monotonic token; a change requests first-responder focus.
    ///   - placeholder: Placeholder shown while the editor is empty.
    ///   - isEnabled: Whether the editor accepts input.
    ///   - font: Editor font.
    ///   - onFocus: Invoked when the editor begins editing.
    ///   - onBlur: Invoked when editing ends and focus left the feed host.
    ///   - onSubmit: Invoked on a bare Return/Enter, when non-`nil`.
    ///   - focusFeedHost: Moves focus to the surrounding feed host for `window`,
    ///     returning `true` when the host accepted focus (the app routes this to
    ///     `focusRightSidebarInActiveMainWindow(mode:.feed,...)`).
    ///   - isFeedFocusHostResponder: Reports whether a responder is the feed
    ///     keyboard-focus host view, so blur is suppressed while focus stays in
    ///     the feed.
    public init(
        text: Binding<String>,
        focusRequest: Int?,
        placeholder: String,
        isEnabled: Bool,
        font: NSFont,
        onFocus: @escaping () -> Void,
        onBlur: @escaping () -> Void,
        onSubmit: (() -> Void)?,
        focusFeedHost: @escaping (NSWindow) -> Bool,
        isFeedFocusHostResponder: @escaping (NSResponder?) -> Bool
    ) {
        self._text = text
        self.focusRequest = focusRequest
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.font = font
        self.onFocus = onFocus
        self.onBlur = onBlur
        self.onSubmit = onSubmit
        self.focusFeedHost = focusFeedHost
        self.isFeedFocusHostResponder = isFeedFocusHostResponder
    }

    /// Coordinates the editor's text-view delegate callbacks and focus handoff.
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
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
            logDebugEvent("feed.editor.activateField")
#endif
            parent.onFocus()
        }

        func blurField() {
            guard let view, let window = view.window, window.firstResponder === view.textView else {
                return
            }
#if DEBUG
            logDebugEvent("feed.editor.blurField frBefore=\(window.firstResponder.feedInlineResponderDebugSummary)")
#endif
            Task { @MainActor in
                if !self.parent.focusFeedHost(window) {
                    window.makeFirstResponder(nil)
                }
            }
        }

        public func textDidBeginEditing(_ notification: Notification) {
            activateField()
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            view?.refreshMetrics()
        }

        public func textDidEndEditing(_ notification: Notification) {
            if !isProgrammaticMutation, let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
            guard let window = view?.window else {
                parent.onBlur()
                return
            }
            let responder = window.firstResponder
            if !parent.isFeedFocusHostResponder(responder) && !(responder is FeedInlineNativeTextView) {
                parent.onBlur()
            }
        }

    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> FeedInlineTextEditorView {
        let view = FeedInlineTextEditorView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        view.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        view.textView.onSubmit = onSubmit
        configure(view)
        context.coordinator.view = view
        return view
    }

    public func updateNSView(_ nsView: FeedInlineTextEditorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
        nsView.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        nsView.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        nsView.textView.onSubmit = onSubmit
        configure(nsView)

        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }

        guard let window = nsView.window else { return }
        let isFirstResponder = window.firstResponder === nsView.textView
        if let focusRequest,
           focusRequest != context.coordinator.lastAppliedFocusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            if isEnabled {
                nsView.focusIfNeeded()
            } else if isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if focusRequest == nil {
            context.coordinator.lastAppliedFocusRequest = nil
            if !isEnabled, isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if !isEnabled, isFirstResponder {
            moveFocusToFeedHost(in: window)
        }
    }

    private func moveFocusToFeedHost(in window: NSWindow) {
        if focusFeedHost(window) {
            return
        }
        window.makeFirstResponder(nil)
    }

    private func configure(_ view: FeedInlineTextEditorView) {
        view.placeholder = placeholder
        view.apply(font: font, isEnabled: isEnabled)
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedInlineTextEditorView,
        context: Context
    ) -> CGSize? {
        nil
    }

    public static func dismantleNSView(_ nsView: FeedInlineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onActivate = nil
        nsView.textView.onEscape = nil
        nsView.textView.onSubmit = nil
    }
}
