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
        if action == #selector(paste(_:)), MobilePasteboardReader().hasAttachmentPayload() {
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

    /// Line cap matching the original `TextField.lineLimit(1...14)`: the field
    /// grows to 14 lines, then holds that height and scrolls internally.
    private static let maximumLineCount = 14

    func makeUIView(context: Context) -> TerminalComposerPromptTextView {
        let view = TerminalComposerPromptTextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = textColor
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.backgroundColor = .clear
        // Zero insets so the text box is EXACTLY the line box, like the SwiftUI
        // TextField this view replaced; the composer's own `.padding(.vertical, 3)`
        // plus the container's 6pt padding produce the design's 9pt text inset.
        // Any inset here would stack on top of those and fatten the field.
        view.textContainerInset = .zero
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

    /// Sizes the field exactly like the SwiftUI `TextField(axis: .vertical)`
    /// with `.lineLimit(1...14)` it replaced: the ideal height is the text's
    /// own height, clamped between one line and fourteen, and the view scrolls
    /// internally only while the cap is binding. Without this, the wrapped
    /// UITextView is at the mercy of whatever frame SwiftUI proposes and the
    /// empty field renders far taller than the 40pt one-line design.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView view: TerminalComposerPromptTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? view.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let lineHeight = ceil(view.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight)
        let chromeHeight = view.textContainerInset.top + view.textContainerInset.bottom
        let minHeight = lineHeight + chromeHeight
        let maxHeight = lineHeight * CGFloat(Self.maximumLineCount) + chromeHeight
        let fitted = view.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let needsScroll = fitted > maxHeight
        if view.isScrollEnabled != needsScroll {
            view.isScrollEnabled = needsScroll
        }
        return CGSize(width: width, height: min(max(fitted, minHeight), maxHeight))
    }
}
#endif
