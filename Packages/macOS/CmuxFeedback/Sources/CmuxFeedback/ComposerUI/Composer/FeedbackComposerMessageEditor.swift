public import SwiftUI

/// SwiftUI wrapper around ``FeedbackComposerMessageEditorView`` that binds the
/// editor's text and forwards accessibility metadata.
public struct FeedbackComposerMessageEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    /// Explicit public initializer: the implicit memberwise init is not visible
    /// across the module boundary now that this type lives in a package.
    public init(
        text: Binding<String>,
        placeholder: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String
    ) {
        self._text = text
        self.placeholder = placeholder
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> FeedbackComposerMessageEditorView {
        let view = FeedbackComposerMessageEditorView()
        view.placeholder = placeholder
        view.textView.string = text
        view.textView.delegate = context.coordinator
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    public func updateNSView(_ nsView: FeedbackComposerMessageEditorView, context: Context) {
        if nsView.textView.string != text {
            nsView.textView.string = text
            nsView.refreshTextLayout()
        }
        nsView.placeholder = placeholder
        nsView.textView.setAccessibilityLabel(accessibilityLabel)
        nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackComposerMessageEditor

        init(parent: FeedbackComposerMessageEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
