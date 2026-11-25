#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The agent chat composer's text: a multi-line field that grows upward with
/// the draft up to `maxLines`, then scrolls (`ComposerFieldHeight`, shared
/// with the terminal composer). Return on the on-screen keyboard
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
    /// A copied image or file pasted into the field (edit menu Paste or
    /// Command-V): the composer attaches it.
    var onPasteAttachments: (() -> Void)?
    /// The draft gained or lost a line (typed, or set from outside): the bottom stack's next
    /// height change moves on `ComposerLineMotion`, not the stack's slower spring.
    var onLineChange: (() -> Void)?

    static let maxLines = ComposerFieldHeight.defaultMaxLines
    static let accessibilityIdentifier = "chat.composer.field"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatFaceHidden) private var faceHidden

    func makeUIView(context: Context) -> ChatComposerTextView {
        let view = ChatComposerTextView()
        view.delegate = context.coordinator
        view.onSend = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // GUI text, so autocorrect and spell check are on, as in every other text app (Leo,
        // 2026-11-23: "you need to not ... entirely disable autocorrect in the gui"; the
        // terminal's composer keeps it off). No capitals and no curly quotes or long dashes:
        // a prompt holds code, paths and flags (full verify D5).
        view.autocorrectionType = .yes
        view.spellCheckingType = .yes
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        ComposerTextTraits.blockSiriSuggestions(view)
        view.returnKeyType = .default
        view.accessibilityIdentifier = Self.accessibilityIdentifier
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.text = text
        view.placeholder = placeholder
        markReadyIfShown()
        return view
    }

    func updateUIView(_ view: ChatComposerTextView, context: Context) {
        ComposerKeyStamp.viewUpdate(view) { update(view, context: context) }
    }

    private func update(_ view: ChatComposerTextView, context: Context) {
        context.coordinator.parent = self
        markReadyIfShown()
        view.onPasteAttachments = onPasteAttachments == nil ? nil : { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPasteAttachments?()
        }
        if context.coordinator.lastTypeSize != dynamicTypeSize {
            context.coordinator.lastTypeSize = dynamicTypeSize
            view.font = .preferredFont(forTextStyle: .body)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
        }
        if view.differs(from: text) {
            view.takeDraft(text)
            if view.lineCountChangePending { onLineChange?() }
            view.invalidateIntrinsicContentSize()
        }
        if view.placeholder != placeholder { view.placeholder = placeholder }
        // Focus follows the binding both ways; the change waits for the
        // current update (a responder change inside it re-enters SwiftUI), and
        // reads the binding again when it runs (a later tap or send wins).
        if isFocused != view.isFirstResponder {
            Task { @MainActor [weak view, weak coordinator = context.coordinator] in
                guard let view, let focus = coordinator?.parent.isFocused else { return }
                if focus, !view.isFirstResponder {
                    // A field built for this focus (the capsule expanding) takes it once in its window.
                    if view.window == nil { view.focusWhenInWindow = true } else { view.becomeFirstResponder() }
                } else if !focus {
                    view.focusWhenInWindow = false
                    if view.isFirstResponder { view.resignFirstResponder() }
                }
            }
        }
    }

    /// Launch to chat open: the frame that first shows a composer (LaunchMarks), not one built
    /// on a terminal's chat face parked out of sight (`chatFaceHidden`); a face swap updates it.
    private func markReadyIfShown() {
        guard !faceHidden else { return }
        LaunchMarks.shared.markNextFrame("chat_composer_ready")
    }

    /// A field torn down while focused (the permission bar replaced it) leaves no focus behind.
    static func dismantleUIView(_ view: ChatComposerTextView, coordinator: Coordinator) {
        if coordinator.parent.isFocused { coordinator.parent.isFocused = false }
    }

    /// Grows a line at a time up to `maxLines`, then scrolls inside
    /// (`ComposerFieldHeight`); measuring changes nothing on the view.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatComposerTextView, context: Context) -> CGSize? {
        uiView.fittingSize(proposedWidth: proposal.width)
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
            if (textView as? ComposerReturnTextView)?.lineCountChangePending == true {
                // A line came or went: the field grows (or shrinks) on the same short spring the
                // stack and the transcript above it take, one motion (`ComposerLineMotion`).
                parent.onLineChange?()
                withAnimation(ComposerLineMotion.animation.unlessReduceMotion) { parent.text = Self.draft(of: textView) }
            } else {
                parent.text = Self.draft(of: textView)
            }
            (textView as? ComposerReturnTextView)?.updatePlaceholder()
            // The height is settled once per edit, and SwiftUI asked again only when it changed.
            (textView as? ComposerReturnTextView)?.settleAfterEdit()
            (textView as? ComposerReturnTextView)?.followCaret()
        }

        /// A native copy, so a long draft compares as a buffer downstream (`draftText()`).
        static func draft(of textView: UITextView) -> String {
            (textView as? ComposerReturnTextView)?.draftText() ?? textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.isFocused { parent.isFocused = true } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.isFocused { parent.isFocused = false } }
    }
}

/// The chat field: takes a focus asked for before it had a window once it gets one.
extension EnvironmentValues {
    /// The chat is built but not shown: a terminal tab's chat face parked at zero opacity
    /// behind its terminal (`TerminalChatPair`).
    @Entry public var chatFaceHidden = false
}

final class ChatComposerTextView: ComposerReturnTextView {
    var focusWhenInWindow = false

    init() {
        super.init(policy: ComposerReturnPolicy(style: .chat, maxLines: ChatComposerField.maxLines))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusWhenInWindow else { return }
        focusWhenInWindow = false
        becomeFirstResponder()
    }
}
#endif
