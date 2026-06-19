public import AppKit
public import SwiftUI
#if DEBUG
internal import CMUXDebugLog
#endif

/// `NSViewRepresentable` exposing the command-palette multiline editor to
/// SwiftUI.
///
/// Binds text, focus, and measured height; submits on Return (allowing
/// Shift-Return to insert a newline) and cancels on Escape. All keyboard
/// decisions are computed inline from the event, so the editor never reaches
/// back into the host beyond the supplied `onSubmit`/`onEscape` closures.
public struct CommandPaletteMultilineTextEditorRepresentable: NSViewRepresentable {
    /// Minimum editor height, derived from the system font's five-line height.
    public static let defaultMinimumHeight = CommandPaletteMultilineTextEditorView.defaultMinimumHeight

    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    /// Creates the multiline editor representable.
    /// - Parameters:
    ///   - placeholder: Placeholder text shown while the editor is empty.
    ///   - accessibilityLabel: Accessibility label for the text view.
    ///   - accessibilityIdentifier: Accessibility identifier for the view and text view.
    ///   - text: Two-way binding to the editor's text.
    ///   - isFocused: Two-way binding reflecting/requesting first-responder focus.
    ///   - measuredHeight: Two-way binding updated with the editor's measured height.
    ///   - maxHeight: Upper bound for the measured height.
    ///   - onSubmit: Invoked with the current text when Return is pressed.
    ///   - onEscape: Invoked when Escape is pressed.
    public init(
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        text: Binding<String>,
        isFocused: Binding<Bool>,
        measuredHeight: Binding<CGFloat>,
        maxHeight: CGFloat,
        onSubmit: @escaping (String) -> Void,
        onEscape: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self._text = text
        self._isFocused = isFocused
        self._measuredHeight = measuredHeight
        self.maxHeight = maxHeight
        self.onSubmit = onSubmit
        self.onEscape = onEscape
    }

    @MainActor public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandPaletteMultilineTextEditorRepresentable
        var isProgrammaticMutation = false
        var pendingFocusRequest = false

        init(parent: CommandPaletteMultilineTextEditorRepresentable) {
            self.parent = parent
        }

        public func textDidBeginEditing(_ notification: Notification) {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.beginEditing focus=\(parent.isFocused ? 1 : 0) " +
                "responder=\((notification.object as? NSResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.command selector=\(NSStringFromSelector(commandSelector)) " +
                "len=\((textView.string as NSString).length) " +
                "sel=\(textView.selectedRange().location):\(textView.selectedRange().length)"
            )
#endif
            return false
        }

        func handleDidBecomeFirstResponder() {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.didBecomeFirstResponder focus=\(parent.isFocused ? 1 : 0)"
            )
#endif
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func handleMeasuredHeight(_ height: CGFloat) {
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            DispatchQueue.main.async {
                self.parent.measuredHeight = height
            }
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
            guard !(editor?.hasMarkedText() ?? false) else { return false }

            let normalizedFlags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])

#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.handleKeyEvent " +
                "\((event).commandPaletteEventDebugSummary) " +
                "normalized=\((normalizedFlags).commandPaletteModifierDebugSummary)"
            )
#endif

            if event.keyCode == 36 || event.keyCode == 76 {
                if normalizedFlags.isEmpty {
                    let currentText = editor?.string ?? parent.text
#if DEBUG
                    logDebugEvent("palette.wsDescription.editor.handleKeyEvent action=submit")
                    logDebugEvent(
                        "palette.wsDescription.editor.handleKeyEvent submitText " +
                        "len=\((currentText as NSString).length) " +
                        "text=\"\((currentText).commandPaletteDebugPreview())\""
                    )
#endif
                    if parent.text != currentText {
                        parent.text = currentText
                    }
                    parent.onSubmit(currentText)
                    return true
                }
                if normalizedFlags == [.shift] {
#if DEBUG
                    logDebugEvent("palette.wsDescription.editor.handleKeyEvent action=allowShiftReturn")
#endif
                    return false
                }
            }

            if event.keyCode == 53, normalizedFlags.isEmpty {
#if DEBUG
                logDebugEvent("palette.wsDescription.editor.handleKeyEvent action=escape")
#endif
                parent.onEscape()
                return true
            }

#if DEBUG
            logDebugEvent("palette.wsDescription.editor.handleKeyEvent action=passThrough")
#endif
            return false
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> CommandPaletteMultilineTextEditorView {
        let view = CommandPaletteMultilineTextEditorView(frame: .zero)
        view.placeholder = placeholder
        view.maximumHeight = maxHeight
        view.textView.string = text
        view.textView.delegate = context.coordinator
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.textView.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        view.textView.onDidBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.handleDidBecomeFirstResponder()
        }
        view.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.handleMeasuredHeight(height)
        }
        view.refreshMetrics()
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.make focus=\(isFocused ? 1 : 0) " +
            "textLen=\((text as NSString).length) " +
            "height=\(String(format: "%.1f", measuredHeight))"
        )
#endif
        return view
    }

    public func updateNSView(_ nsView: CommandPaletteMultilineTextEditorView, context: Context) {
        context.coordinator.parent = self
        nsView.placeholder = placeholder
        nsView.maximumHeight = maxHeight
        nsView.textView.setAccessibilityLabel(accessibilityLabel)
        nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)

        if nsView.textView.string != text {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
        }
        nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.handleMeasuredHeight(height)
        }
        nsView.refreshMetrics()

        guard let window = nsView.window else {
#if DEBUG
            if isFocused {
                logDebugEvent(
                    "palette.wsDescription.editor.update waitingForWindow focus=1 " +
                    "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0)"
                )
            }
#endif
            return
        }
        let isFirstResponder = window.firstResponder === nsView.textView
#if DEBUG
        if isFocused || context.coordinator.pendingFocusRequest {
            logDebugEvent(
                "palette.wsDescription.editor.update focus=\(isFocused ? 1 : 0) " +
                "isFirstResponder=\(isFirstResponder ? 1 : 0) " +
                "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0) " +
                "window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
        }
#endif
        if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
            context.coordinator.pendingFocusRequest = true
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.update scheduleFocus window={\((window).commandPaletteWindowDebugSummary)} " +
                "fr=\((window.firstResponder).commandPaletteResponderDebugSummary)"
            )
#endif
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                guard let coordinator else { return }
                coordinator.pendingFocusRequest = false
                guard coordinator.parent.isFocused, let nsView else { return }
                nsView.focusIfNeeded()
            }
        }
    }

    public static func dismantleNSView(_ nsView: CommandPaletteMultilineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onHandleKeyEvent = nil
        nsView.textView.onDidBecomeFirstResponder = nil
        nsView.onMeasuredHeightChange = nil
    }
}
