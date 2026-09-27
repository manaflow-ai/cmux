#if os(iOS)
import SwiftUI
import UIKit

/// The terminal composer's message field, inheriting the shared paste
/// interception so pasted images/files stage as pending attachments.
@MainActor
final class TerminalComposerPromptTextView: MobilePasteInterceptingTextView {
    /// Placeholder shown while the field is empty, owned here so visibility
    /// tracks every text mutation (typing, paste, dictation, external clears).
    let placeholderLabel = UILabel()

    override var text: String! {
        didSet { placeholderLabel.isHidden = !(text ?? "").isEmpty }
    }

    // Typing mutates the text storage without passing through the `text`
    // setter, but every content change triggers layout, so visibility is
    // re-derived here to cover keystrokes, dictation, and IME composition.
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.isHidden = !(text ?? "").isEmpty
    }
}

/// A UIKit-backed replacement for the composer's `TextField(axis: .vertical)`
/// whose ONLY behavioral addition is paste interception (system edit menu,
/// hardware Cmd+V, keyboard paste key) for attachment content — SwiftUI's
/// `TextField` offers no paste hook on iOS.
///
/// Geometry contract: the editor reproduces `TextField(axis: .vertical)
/// .lineLimit(1...14)` exactly. The surrounding container provides the field's
/// 40pt one-line floor and paddings, so the editor carries NO insets of its
/// own (any inset here would stack on the container's and fatten the field);
/// its `sizeThatFits` reports the text's own height clamped to 1–14 lines,
/// enabling internal scrolling only past the cap.
struct TerminalComposerPromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let textColor: UIColor
    let isDisabled: Bool
    /// Stages pasted images/files as attachments; `true` consumes the paste.
    let pasteAttachments: () -> Bool

    /// The 1...14 line growth window mirrored from the replaced `TextField`.
    private static let maximumLineCount: CGFloat = 14

    func makeCoordinator() -> TaskComposerPromptEditorCoordinator {
        TaskComposerPromptEditorCoordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> TerminalComposerPromptTextView {
        let textView = TerminalComposerPromptTextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        // The container already pads the field; zero insets keep the one-line
        // field at its 40pt baseline instead of stacking heights.
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        // Natural-language input to an agent: the same text assistance the
        // replaced TextField enabled (the raw terminal field keeps these off).
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.accessibilityIdentifier = "MobileComposerField"
        textView.pasteAttachments = pasteAttachments

        let placeholderLabel = textView.placeholderLabel
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
        ])

        applyState(to: textView)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: TerminalComposerPromptTextView, context: Context) {
        context.coordinator.update(text: $text, isFocused: $isFocused)
        textView.pasteAttachments = pasteAttachments
        applyState(to: textView)

        // Assigning the same text again resets UITextView's selection/caret
        // layout; user edits already changed the backing view, so only external
        // mutations (a send clearing the draft, a terminal switch swapping it)
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
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: TerminalComposerPromptTextView,
        context: Context
    ) -> CGSize? {
        // An unbounded proposal would measure (and report) an infinite width;
        // fall back to system sizing until a concrete width arrives.
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        let lineHeight = (textView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let fitted = textView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let minimum = ceil(lineHeight)
        let maximum = ceil(lineHeight * Self.maximumLineCount)
        // Internal scrolling only once the 14-line cap binds; below it the
        // field grows and the band reserves the height.
        let shouldScroll = fitted > maximum
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
        }
        return CGSize(width: width, height: min(max(fitted, minimum), maximum))
    }

    private func applyState(to textView: TerminalComposerPromptTextView) {
        textView.placeholderLabel.text = placeholder
        textView.placeholderLabel.isHidden = !textView.text.isEmpty
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        textView.isEditable = !isDisabled
        textView.isUserInteractionEnabled = !isDisabled
        if isDisabled, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }
}
#endif
