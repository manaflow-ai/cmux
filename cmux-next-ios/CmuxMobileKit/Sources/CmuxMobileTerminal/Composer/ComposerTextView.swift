#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The composer's text field: a UITextView, so the screen controls what a
/// SwiftUI TextField does not expose: the dark keyboard (iOS 27 no longer
/// derives it from the field's trait), terminal-safe text traits, and growth
/// upward from 1 line to the cap before it scrolls inside (`ComposerHeightCap`;
/// the height rule is `ComposerFieldHeight`, shared with the agent chat composer).
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
    /// A copied image or file pasted into the field (edit menu Paste or
    /// Command-V): it becomes an attachment. Nil: the composer takes none.
    var onPasteAttachments: (() -> Void)?
    /// The composer's Autocorrect toggle (`CmuxMobilePreferences.terminalComposerAutocorrect`):
    /// on, the keyboard corrects, spell-checks and predicts as in the chat
    /// composer; off (the default), a shell line is typed as is.
    var autocorrect = false
    /// The attachment strip's height above the field inside the card (0:
    /// none): the field gives it that much of the cap.
    var stripReserve: CGFloat = 0
    /// Where the screen reads the field's strip overlap (`ComposerFieldRef`).
    var fieldRef: ComposerFieldRef?

    /// Six lines, then the draft scrolls inside, as the chat composer and
    /// ChatGPT's do (Leo, 2026-11-23: "composer growth in terminal view on ios
    /// is most certainly too high"; it had classic cmux iOS's 14).
    static var maxLines: Int { ComposerHeightCap.terminalLines }
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
        // No inset, as the agent chat's field: the card (`ComposerCard`)
        // places the text, one line centered on the row of 36 pt circles.
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.keyboardAppearance = .dark
        Self.applyAutocorrect(autocorrect, to: view)
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
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
        ComposerKeyStamp.viewUpdate(view) { update(view, context: context) }
    }

    private func update(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastTypeSize != dynamicTypeSize {
            context.coordinator.lastTypeSize = dynamicTypeSize
            view.font = .preferredFont(forTextStyle: .body)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
        }
        if view.differs(from: text) { view.takeDraft(text) }
        fieldRef?.view = view
        view.stripReserve = stripReserve
        view.placeholder = placeholder
        view.onPasteAttachments = onPasteAttachments == nil ? nil : { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPasteAttachments?()
        }
        if Self.applyAutocorrect(autocorrect, to: view), view.isFirstResponder {
            // The open keyboard reads its traits only when asked again.
            view.reloadInputViews()
        }
        view.isEditable = !isDisabled
        if isDisabled, view.isFirstResponder { view.resignFirstResponder() }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Locked by dictation: the field takes focus once it settles, not now.
            if !isDisabled { view.becomeFirstResponder() }
        }
    }

    /// Grows a line at a time up to `maxLines`, then scrolls inside
    /// (`ComposerFieldHeight`); measuring changes nothing on the view.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        uiView.fittingSize(proposedWidth: proposal.width)
    }

    /// Sets the correction traits; true when one changed. Smart quotes and
    /// dashes stay off either way: a quote typed to a shell stays a quote.
    @discardableResult
    static func applyAutocorrect(_ on: Bool, to view: UITextView) -> Bool {
        let correction: UITextAutocorrectionType = on ? .yes : .no
        let spelling: UITextSpellCheckingType = on ? .yes : .no
        let prediction: UITextInlinePredictionType = on ? .default : .no
        guard view.autocorrectionType != correction || view.spellCheckingType != spelling
            || view.inlinePredictionType != prediction else { return false }
        view.autocorrectionType = correction
        view.spellCheckingType = spelling
        view.inlinePredictionType = prediction
        return true
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
            // A native copy, so a long draft compares as a buffer downstream (`draftText()`).
            parent.text = (textView as? ComposerReturnTextView)?.draftText() ?? textView.text
            (textView as? ComposerUITextView)?.updatePlaceholder()
            // The height is settled once per edit, and SwiftUI asked again only when it changed.
            (textView as? ComposerReturnTextView)?.settleAfterEdit()
            (textView as? ComposerUITextView)?.followCaret()
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
