#if os(iOS)
import SwiftUI
import UIKit

/// A multiline prompt editor whose UIKit scroll position is not recreated by
/// unrelated SwiftUI updates, such as changing the selected task model.
struct TaskComposerPromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isDisabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    /// Stages pasted images/files as attachments; `true` consumes the paste.
    let pasteAttachments: () -> Bool

    func makeCoordinator() -> TaskComposerPromptEditorCoordinator {
        TaskComposerPromptEditorCoordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> TaskComposerPromptTextView {
        let textView = TaskComposerPromptTextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .title3)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 5
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .none
        textView.text = text
        textView.accessibilityIdentifier = "MobileTaskComposerPrompt"
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityHint = accessibilityHint
        textView.restoreManualContentOffset = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.restoreManualContentOffset(in: textView)
        }
        textView.pasteAttachments = pasteAttachments
        updateInteractionState(of: textView)
        return textView
    }

    func updateUIView(_ textView: TaskComposerPromptTextView, context: Context) {
        context.coordinator.update(text: $text, isFocused: $isFocused)
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityHint = accessibilityHint
        textView.pasteAttachments = pasteAttachments
        updateInteractionState(of: textView)

        // Assigning the same text again resets UITextView's selection/caret
        // layout and can scroll an active editor back to that caret. User edits
        // already changed the backing UITextView, so only external mutations
        // need an assignment here.
        if textView.text != text {
            let selection = textView.selectedRange
            textView.text = text
            let textLength = (text as NSString).length
            let location = min(selection.location, textLength)
            textView.selectedRange = NSRange(
                location: location,
                length: min(selection.length, textLength - location)
            )
        }

        context.coordinator.restoreManualContentOffset(in: textView)
    }

    private func updateInteractionState(of textView: UITextView) {
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.isUserInteractionEnabled = !isDisabled
        if isDisabled, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }
}
#endif
