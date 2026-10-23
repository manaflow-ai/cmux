#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The composer's text field: a UITextView, so the screen controls what a
/// SwiftUI TextField does not expose: the dark keyboard (iOS 27 no longer
/// derives it from the field's trait), Return as send, terminal-safe text
/// traits, and growth from 1 to 6 lines before it scrolls.
///
/// Return sends from either keyboard (SPEC 10.2, `ComposerReturnStyle.terminal`).
/// A multi-line draft still has a way to start a new line: Shift-Return or
/// Option-Return on a hardware keyboard, or New Line in the field's edit menu
/// (tap the focused field); pasted lines stay as they are. The draft goes to
/// the program as one paste (`ComposerSubmit`).
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    /// A focus request made before the field existed (a new terminal tab):
    /// take focus once the field is in a window.
    var focusOnAppear = false
    let onFocusChange: (Bool) -> Void
    let onReturn: () -> Void
    /// Asked before typed text is inserted; false: the key went elsewhere
    /// (the terminal, with the key bar's ctrl or alt on).
    var shouldInsert: (String) -> Bool = { _ in true }

    static let maxLines = 6
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
        // One line is as tall as the + and send circles, so they sit with
        // equal insets on every side of the card (user note 2026-10-14).
        let inset = ComposerMetrics().verticalTextInset(lineHeight: view.font?.lineHeight ?? 20)
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
        view.returnKeyType = .send
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
            let inset = ComposerMetrics().verticalTextInset(lineHeight: view.font?.lineHeight ?? 20)
            view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        if view.text != text { view.text = text }
        view.placeholder = placeholder
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            view.becomeFirstResponder()
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
            // Return sends (SPEC 10.2); Shift-Return and New Line insert their own
            // line break; a pasted multi-line text stays as is.
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

/// The terminal composer's text view: Return sends, New Line in the edit menu.
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
    /// Proof: `verify/termqa/afprobe/run.sh`. New Line stays, and only
    /// once there is text (an empty draft has no line to break).
    override func buildMenu(with builder: any UIMenuBuilder) {
        offersNewLineMenuItem = !(text ?? "").isEmpty
        builder.remove(menu: .autoFill)
        super.buildMenu(with: builder)
    }

    init() {
        super.init(policy: ComposerReturnPolicy(style: .terminal, maxLines: ComposerTextView.maxLines))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
