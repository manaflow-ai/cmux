public import AppKit
public import SwiftUI
#if DEBUG
import os
#endif

/// SwiftUI wrapper around the `NSTextView`-backed inline Feed reply/answer
/// editor. It bridges a `String` binding to `FeedInlineTextEditorView`, drives
/// programmatic focus from `focusRequest`, and reports focus transitions
/// through `onFocus`/`onBlur` plus an optional `onSubmit`.
///
/// Focus seams are injected so this view never references the app's
/// `AppDelegate` or window focus controller:
///
/// - `moveFocusToFeedHost` asks the app to move keyboard focus to the Feed
///   sidebar host for a given window, returning `true` when it did. The app is
///   the only caller of `AppDelegate.focusRightSidebarInActiveMainWindow`.
///   When it returns `false` the editor clears the window's first responder
///   itself, matching the legacy fallback.
/// - `responderRetainsFeedFocus` lets the app decide whether a window's new
///   first responder still belongs to the Feed focus domain (the Feed keyboard
///   host or another inline editor), so end-of-editing does not spuriously fire
///   `onBlur` while focus is merely hopping within the Feed sidebar.
public struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String

    let focusRequest: Int?
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: (() -> Void)?
    let moveFocusToFeedHost: @MainActor (NSWindow) -> Bool
    let responderRetainsFeedFocus: (NSResponder) -> Bool

    public init(
        text: Binding<String>,
        focusRequest: Int?,
        placeholder: String,
        isEnabled: Bool,
        font: NSFont,
        onFocus: @escaping () -> Void,
        onBlur: @escaping () -> Void,
        onSubmit: (() -> Void)?,
        moveFocusToFeedHost: @escaping @MainActor (NSWindow) -> Bool,
        responderRetainsFeedFocus: @escaping (NSResponder) -> Bool
    ) {
        self._text = text
        self.focusRequest = focusRequest
        self.placeholder = placeholder
        self.isEnabled = isEnabled
        self.font = font
        self.onFocus = onFocus
        self.onBlur = onBlur
        self.onSubmit = onSubmit
        self.moveFocusToFeedHost = moveFocusToFeedHost
        self.responderRetainsFeedFocus = responderRetainsFeedFocus
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedInlineTextField
        var isProgrammaticMutation = false
        weak var view: FeedInlineTextEditorView?
        var lastAppliedFocusRequest: Int?

#if DEBUG
        private static let log = Logger(subsystem: "com.cmux.feed", category: "InlineEditor")

        private static func responderSummary(_ responder: NSResponder?) -> String {
            guard let responder else { return "nil" }
            return String(describing: type(of: responder))
        }
#endif

        init(parent: FeedInlineTextField) {
            self.parent = parent
            self.lastAppliedFocusRequest = parent.focusRequest
        }

        func activateField() {
#if DEBUG
            Self.log.debug("feed.editor.activateField")
#endif
            parent.onFocus()
        }

        func blurField() {
            guard let view, let window = view.window, window.firstResponder === view.textView else {
                return
            }
#if DEBUG
            Self.log.debug("feed.editor.blurField frBefore=\(Self.responderSummary(window.firstResponder), privacy: .public)")
#endif
            let move = parent.moveFocusToFeedHost
            Task { @MainActor in
                if move(window) != true {
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
            if let responder = window.firstResponder,
               parent.responderRetainsFeedFocus(responder) {
                return
            }
            parent.onBlur()
        }
    }

    /// Blurs whichever inline Feed editor currently holds first responder, if
    /// any. Used by the Feed panel when selecting a row should take keyboard
    /// focus away from an active inline editor.
    public static func blurActiveEditor() {
        FeedInlineNativeTextView.blurActiveEditor()
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
                relocateFocusToFeedHost(in: window)
            }
        } else if focusRequest == nil {
            context.coordinator.lastAppliedFocusRequest = nil
            if !isEnabled, isFirstResponder {
                relocateFocusToFeedHost(in: window)
            }
        } else if !isEnabled, isFirstResponder {
            relocateFocusToFeedHost(in: window)
        }
    }

    private func relocateFocusToFeedHost(in window: NSWindow) {
        if moveFocusToFeedHost(window) == true {
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
