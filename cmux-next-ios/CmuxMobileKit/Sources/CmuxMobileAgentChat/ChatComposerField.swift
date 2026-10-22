#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The agent chat composer's text: a multi-line field that grows with the
/// draft up to `maxLines`, then scrolls. Return on the on-screen keyboard
/// starts a new line and the send button sends; on a hardware keyboard
/// Return sends and Shift-Return (or Option-Return) starts a new line
/// (`ComposerReturnStyle.chat`, as in the ChatGPT and Claude iPhone apps).
/// A UITextView, because a SwiftUI TextField decides Return by itself.
struct ChatComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    /// A hardware Return: send the draft (the composer checks there is one).
    let onSend: () -> Void

    static let maxLines = 8
    static let accessibilityIdentifier = "chat.composer.field"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> ComposerReturnTextView {
        let view = ComposerReturnTextView(policy: ComposerReturnPolicy(style: .chat, maxLines: Self.maxLines))
        view.delegate = context.coordinator
        view.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        // Prompts are code-like: no autocorrect, no capitals (full verify D5).
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.returnKeyType = .default
        view.accessibilityIdentifier = Self.accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.text = text
        view.placeholder = placeholder
        return view
    }

    func updateUIView(_ view: ComposerReturnTextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastTypeSize != dynamicTypeSize {
            context.coordinator.lastTypeSize = dynamicTypeSize
            view.font = .preferredFont(forTextStyle: .body)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
        }
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        if view.placeholder != placeholder { view.placeholder = placeholder }
        // Focus follows the binding both ways; the change waits for the
        // current update (a responder change inside it re-enters SwiftUI).
        if isFocused != view.isFirstResponder {
            let focus = isFocused
            Task { @MainActor [weak view] in
                guard let view, view.window != nil else { return }
                if focus, !view.isFirstResponder { view.becomeFirstResponder() } else if !focus, view.isFirstResponder { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerReturnTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maxHeight = ceil(font.lineHeight * CGFloat(uiView.returnPolicy.maxLines) + insets)
        let fitting = max(ceil(font.lineHeight + insets), uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let scrolls = fitting > maxHeight
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(fitting, maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ChatComposerField
        var lastTypeSize: DynamicTypeSize?

        init(parent: ChatComposerField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let view = textView as? ComposerReturnTextView else { return true }
            return view.returnShouldInsert(text)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? ComposerReturnTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
            if textView.isScrollEnabled { textView.scrollRangeToVisible(textView.selectedRange) }
        }

        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.isFocused { parent.isFocused = false } }
    }
}
#endif
