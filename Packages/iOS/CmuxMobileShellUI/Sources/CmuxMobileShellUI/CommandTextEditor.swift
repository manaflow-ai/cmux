#if os(iOS)
import SwiftUI
import UIKit

/// A script editor that keeps punctuation and whitespace literal during typing and paste.
struct CommandTextEditor: UIViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    @State private var focused = false

    func makeCoordinator() -> TaskComposerPromptEditorCoordinator {
        TaskComposerPromptEditorCoordinator(text: $text, isFocused: $focused)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        TerminalComposerPromptEditor.configureTextInputTraits(view)
        view.smartInsertDeleteType = .no
        view.accessibilityIdentifier = "MobileTerminalCommandEditor"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.update(text: $text, isFocused: $focused)
        view.isEditable = enabled
        if view.text != text { view.text = text }
    }
}
#endif
