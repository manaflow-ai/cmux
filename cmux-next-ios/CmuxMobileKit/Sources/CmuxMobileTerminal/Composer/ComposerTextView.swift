#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The composer's text field: a UITextView, so the screen controls what a
/// SwiftUI TextField does not expose: the dark keyboard (iOS 27 no longer
/// derives it from the field's trait), terminal-safe text traits, and growth
/// from 1 to 14 lines before it scrolls (classic cmux iOS).
///
/// Return starts a new line from either keyboard and only the send button
/// sends (classic cmux iOS, `ComposerReturnStyle.message`); the key row's ⏎
/// sends a bare Return. The draft goes to the program as one paste
/// (`ComposerSubmit`).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    /// A focus request made before the field existed (a new terminal tab):
    /// take focus once the field is in a window.
    var focusOnAppear = false
    /// Dictation owns the text: the field takes no edits until it settles,
    /// so an edit is never overwritten by the next result (classic).
    var isDisabled = false
    let onFocusChange: (Bool) -> Void
    let onReturn: () -> Void
    /// Asked before typed text is inserted; false: the key went elsewhere
    /// (the terminal, with the key bar's ctrl or alt on).
    var shouldInsert: (String) -> Bool = { _ in true }

    static let maxLines = 14
    /// Read so a live text size change updates the view (Codex QA F10): the
    /// insets follow the new line height and SwiftUI measures it again.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onReturn() }
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .label
        // With the field container's 6 pt padding, one line is 40 pt: as tall
        // as the paperclip and mic circles beside it (classic).
        let inset = TerminalDockMetrics.textInset
        view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.keyboardAppearance = .dark
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        // A shell line is not prose (SPEC M2): no QuickType bar, no AutoFill
        // callout, no Writing Tools.
        view.textContentType = nil
        view.writingToolsBehavior = .none
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.returnKeyType = .default
        view.accessibilityIdentifier = "terminal.composer.field"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.lastFocusRequest = focusRequest
        view.focusWhenInWindow = focusOnAppear
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastTypeSize != dynamicTypeSize {
            context.coordinator.lastTypeSize = dynamicTypeSize
            view.font = .preferredFont(forTextStyle: .body)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        if view.text != text { view.text = text }
        view.placeholder = placeholder
        view.isEditable = !isDisabled
        if isDisabled, view.isFirstResponder { view.resignFirstResponder() }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Locked by dictation: the field takes focus once it settles, not now.
            if !isDisabled { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let font = uiView.font ?? .preferredFont(forTextStyle: .body)
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maxHeight = ceil(font.lineHeight * CGFloat(uiView.returnPolicy.maxLines) + insets)
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let scrolls = fitting > maxHeight
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        return CGSize(width: width, height: min(fitting, maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var lastFocusRequest = 0
        var lastTypeSize: DynamicTypeSize?

        init(parent: ComposerTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Return starts a new line (`ComposerReturnStyle.message`); a pasted
            // multi-line text stays as is.
            if text == "\n", let view = textView as? ComposerReturnTextView {
                return view.insertingLineBreak || view.returnShouldInsert(text)
            }
            return text.isEmpty || parent.shouldInsert(text)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? ComposerUITextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusChange(false) }
    }
}

/// The terminal composer's text view: Return starts a new line.
final class ComposerUITextView: ComposerReturnTextView {
    var focusWhenInWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusWhenInWindow else { return }
        focusWhenInWindow = false
        becomeFirstResponder()
    }

    /// A tap on the focused composer shows the edit menu; on an empty field
    /// its only item was AutoFill, a pill over the last terminal rows that
    /// stayed until dismissed (r13 D3, verifier 2026-10-19: 67 of 67 s with
    /// the keyboard up). A shell line has nothing to AutoFill (SPEC M2).
    /// Proof: `verify/termqa/afprobe/run.sh`.
    override func buildMenu(with builder: any UIMenuBuilder) {
        builder.remove(menu: .autoFill)
        super.buildMenu(with: builder)
    }

    init() {
        super.init(policy: ComposerReturnPolicy(style: .message, maxLines: ComposerTextView.maxLines))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
