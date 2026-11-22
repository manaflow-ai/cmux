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
    /// Emoji shortcodes (`:plead`): the list's state, which this field's text view drives.
    var emoji: ComposerEmoji?

    static let maxLines = ComposerFieldHeight.defaultMaxLines
    static let accessibilityIdentifier = "chat.composer.field"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatFaceHidden) private var faceHidden

    func makeUIView(context: Context) -> ChatComposerTextView {
        let view = ChatComposerTextView()
        view.delegate = context.coordinator
        // A hardware Return writes the highlighted emoji while the list is open, else sends.
        view.onSend = { [weak coordinator = context.coordinator] in
            if coordinator?.parent.emoji?.accept() == true { return }
            coordinator?.parent.onSend()
        }
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
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
        markReadyIfShown()
        return view
    }

    func updateUIView(_ view: ChatComposerTextView, context: Context) {
        context.coordinator.parent = self
        markReadyIfShown()
        if view.emoji !== emoji {
            view.emoji = emoji
            emoji?.textView = view
            emoji?.onTextChange = { [weak coordinator = context.coordinator, weak view] text in
                guard let coordinator, let view else { return }
                coordinator.textViewDidChange(view)
                if coordinator.parent.text != text { coordinator.parent.text = text }
            }
        }
        view.onPasteAttachments = onPasteAttachments == nil ? nil : { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPasteAttachments?()
        }
        if context.coordinator.lastTypeSize != dynamicTypeSize {
            context.coordinator.lastTypeSize = dynamicTypeSize
            view.font = .preferredFont(forTextStyle: .body)
            view.refreshPlaceholderFont()
            view.invalidateIntrinsicContentSize()
        }
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
            // Sent, or written from outside (a mention, a returned draft): the emoji list follows,
            // after this update (it is state the composer draws).
            if let emoji { DispatchQueue.main.async { [weak view] in if let view { emoji.refresh(view) } } }
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
        /// The pending edit is the person typing `:` (it may close a `:code:`).
        private var typedColon = false

        init(parent: ChatComposerField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let undoing = textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
            typedColon = text == ":" && range.length == 0 && textView.markedTextRange == nil && !undoing
            guard text == "\n", let view = textView as? ComposerReturnTextView else { return true }
            // The on-screen keyboard's Return writes the highlighted emoji while the list is open.
            if textView.markedTextRange == nil, let emoji = parent.emoji, emoji.isOpen, !view.insertingLineBreak {
                // Next turn: never edit the text inside the delegate's own change check.
                DispatchQueue.main.async { emoji.accept() }
                return false
            }
            return view.returnShouldInsert(text)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? ComposerReturnTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
            (textView as? ComposerReturnTextView)?.followCaret()
            let colon = typedColon
            typedColon = false
            parent.emoji?.textDidChange(textView, typedColon: colon)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.emoji?.refresh(textView)
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
    weak var emoji: ComposerEmoji?

    init() {
        super.init(policy: ComposerReturnPolicy(style: .chat, maxLines: ChatComposerField.maxLines))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Emoji list keys

    /// While the emoji list is open: Tab writes the highlighted row, the arrows move it, Esc
    /// closes the list. (Return is the field's send, which writes the row first: `onSend`.)
    override var keyCommands: [UIKeyCommand]? {
        guard let emoji, emoji.isOpen, markedTextRange == nil else { return super.keyCommands }
        let commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(emojiAccept)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(emojiUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(emojiDown)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(emojiDismiss)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }

    @objc private func emojiAccept() { emoji?.accept() }
    @objc private func emojiUp() { emoji?.move(-1) }
    @objc private func emojiDown() { emoji?.move(1) }
    @objc private func emojiDismiss() { emoji?.dismiss() }

    /// A pasted `:code:` goes in as its emoji: the paste is written converted, in one step, so
    /// one undo removes the whole paste (the Mac composer's rule).
    override func paste(_ sender: Any?) {
        guard emoji != nil, markedTextRange == nil, onPasteAttachments == nil || !UIPasteboard.general.composerPastesAttachments,
              let pasted = UIPasteboard.general.string,
              let converted = EmojiShortcodes.convertingPaste(pasted, table: .bundled, tone: EmojiPrefsStore.prefs.tone) else {
            super.paste(sender)
            return
        }
        if let tone = converted.rememberTone { EmojiPrefsStore.prefs.tone = tone }
        // insertText is the keyboard's own path: one undo step, and the delegate sees the change.
        insertText(converted.text)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, focusWhenInWindow else { return }
        focusWhenInWindow = false
        becomeFirstResponder()
    }
}
#endif
