#if os(iOS)
import SwiftUI
import UIKit
import CmuxMobileSupport

final class TerminalComposerPromptTextView: UITextView {
    var pasteAttachment: (() -> Bool)?
    let placeholderLabel = UILabel()

    override func paste(_ sender: Any?) {
        guard pasteAttachment?() != true else { return }
        super.paste(sender)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(
            x: textContainerInset.left + textContainer.lineFragmentPadding,
            y: textContainerInset.top,
            width: bounds.width - textContainerInset.left - textContainerInset.right,
            height: font?.lineHeight ?? 20
        )
        placeholderLabel.isHidden = !text.isEmpty
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), MobilePasteboardReader.hasAttachmentPayload() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

struct TerminalComposerPromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isDisabled: Bool
    let placeholder: String
    let textColor: UIColor
    let pasteAttachment: () -> Bool

    func makeCoordinator() -> TaskComposerPromptEditorCoordinator {
        TaskComposerPromptEditorCoordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> TerminalComposerPromptTextView {
        let view = TerminalComposerPromptTextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = textColor
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.text = text
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.textColor = textColor.withAlphaComponent(0.55)
        view.placeholderLabel.font = view.font
        view.addSubview(view.placeholderLabel)
        view.accessibilityIdentifier = "MobileComposerField"
        view.pasteAttachment = pasteAttachment
        view.textColor = textColor
        view.placeholderLabel.textColor = textColor.withAlphaComponent(0.55)
        update(view)
        return view
    }

    func updateUIView(_ view: TerminalComposerPromptTextView, context: Context) {
        context.coordinator.update(text: $text, isFocused: $isFocused)
        view.pasteAttachment = pasteAttachment
        view.placeholderLabel.text = placeholder
        if view.text != text { view.text = text }
        view.placeholderLabel.isHidden = !text.isEmpty
        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
        update(view)
    }

    private func update(_ view: UITextView) {
        view.isEditable = !isDisabled
        view.isSelectable = !isDisabled
        view.isUserInteractionEnabled = !isDisabled
        if isDisabled, view.isFirstResponder { view.resignFirstResponder() }
    }
}
#endif
