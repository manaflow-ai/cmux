#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// The long-press menu's "Select": Messages selects the bubble's whole text
/// in place, with grab handles and the system edit menu (Copy, Look Up,
/// Translate, more), instead of entering multi-message select mode ("More…").
///
/// A transparent, selectable `UITextView` laid exactly over the bubble's
/// label supplies the system selection UI; the label keeps drawing the text
/// (effects, mentions, links) underneath, so nothing visibly changes but the
/// highlight and handles.
final class BubbleTextSelectionView: UITextView, UITextViewDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    let rowID: String
    let messageID: String
    /// The bubble's own text, for Copy (the overlay's copy is drawn clear).
    private let plainText: String
    var onEnd: (() -> Void)?
    /// Reply with Selection, when the host takes it (`onReplyWithSelection`).
    private let onReply: (@MainActor (ConversationSelectionReply) -> Void)?
    private var ended = false
    /// UITextView keeps its own edit menu private; this one gathers the same
    /// system actions from the responder chain: Copy, Look Up, Translate,
    /// Share. Without Reply with Selection it has no delegate, so the menu
    /// is the system's alone.
    private lazy var menuInteraction = UIEditMenuInteraction(delegate: onReply == nil ? nil : self as any UIEditMenuInteractionDelegate)

    init(rowID: String, messageID: String, text: NSAttributedString, tint: UIColor,
         onReply: (@MainActor (ConversationSelectionReply) -> Void)? = nil) {
        self.rowID = rowID
        self.messageID = messageID
        self.onReply = onReply
        plainText = text.string
        super.init(frame: .zero, textContainer: nil)
        let clear = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: clear.length)
        clear.removeAttribute(.link, range: whole)
        clear.addAttribute(.foregroundColor, value: UIColor.clear, range: whole)
        attributedText = clear
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        tintColor = tint
        delegate = self
        // VoiceOver already reads (and offers Copy on) the bubble itself.
        accessibilityElementsHidden = true
        addInteraction(menuInteraction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Selects every character and shows the edit menu above it.
    func selectAllAndShowMenu() {
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: (text as NSString).length)
        showEditMenu()
    }

    /// Messages hangs the menu under the selected text, pointing up.
    func showEditMenu() {
        let rects = selectedTextRange.map { selectionRects(for: $0).map(\.rect).filter { !$0.isEmpty } } ?? []
        let selection = rects.dropFirst().reduce(rects.first ?? bounds) { $0.union($1) }
        let anchor = BubbleSelectionMenuGeometry.anchor(selection: selection)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor.point)
        if anchor.pointsUp { configuration.preferredArrowDirection = .up }
        menuInteraction.presentEditMenu(with: configuration)
    }

    /// Copies what the bubble shows, as plain text (the overlay's own
    /// attributes are transparent).
    override func copy(_ sender: Any?) {
        guard let range = Range(selectedRange, in: plainText) else { return }
        UIPasteboard.general.string = String(plainText[range])
    }

    /// The selected words, as Reply with Selection hands them on; nil with
    /// nothing but blank space selected.
    var selectionReply: ConversationSelectionReply? {
        ConversationSelectionReply(messageID: messageID, text: plainText, selectedRange: selectedRange)
    }

    /// Reply with Selection first, then the system's actions; none without
    /// the host's hook or a selection worth quoting.
    private func replyMenuElements() -> [UIMenuElement] {
        guard onReply != nil, selectionReply != nil else { return [] }
        let title = String(localized: "conversation.menu.replyWithSelection", defaultValue: "Reply with Selection", bundle: .module)
        return [UIAction(title: title, image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.replyWithSelection()
        }]
    }

    /// Hands the selection to the host (the menu item's action).
    @discardableResult
    func replyWithSelection() -> Bool {
        guard let onReply, let reply = selectionReply else { return false }
        onReply(reply)
        return true
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: replyMenuElements() + suggestedActions)
    }

    /// The menu UIKit shows itself after the handles move.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let reply = replyMenuElements()
        return reply.isEmpty ? nil : UIMenu(children: reply + suggestedActions)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Tapping the selection away (or any collapse) ends it, as in Messages.
        if selectedRange.length == 0 { end() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { end() }
        return resigned
    }

    func end() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }
}

extension ConversationViewController {
    /// Whether "Select" applies: the row draws text in a bubble.
    func canSelectText(in cell: MessageCell) -> Bool {
        !cell.textLabel.isHidden && cell.cellLayout?.textFrame != nil && (cell.textLabel.attributedText?.length ?? 0) > 0
    }

    func beginTextSelection(rowID: String) {
        endTextSelection()
        guard let indexPath = indexPath(for: rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model, canSelectText(in: cell),
              let text = cell.textLabel.attributedText else { return }
        // The keyboard would cover the menu; Messages dismisses it too.
        composer.textView.resignFirstResponder()
        let selection = BubbleTextSelectionView(
            rowID: rowID,
            messageID: model.message.id,
            text: text,
            tint: model.isOutgoing ? .white : .systemBlue,
            onReply: replyWithSelectionHandler()
        )
        selection.frame = cell.textLabel.convert(cell.textLabel.bounds, to: collectionView)
        selection.onEnd = { [weak self, weak selection] in
            guard let self, let selection else { return }
            if self.textSelection === selection { self.textSelection = nil }
            selection.removeFromSuperview()
        }
        collectionView.addSubview(selection)
        textSelection = selection
        selection.selectAllAndShowMenu()
    }

    /// The selection's Reply with Selection action: the selection ends, then
    /// the host's hook runs. nil (no menu item) without the hook.
    private func replyWithSelectionHandler() -> (@MainActor (ConversationSelectionReply) -> Void)? {
        guard let handler = onReplyWithSelection else { return nil }
        return { [weak self] reply in
            self?.endTextSelection()
            handler(reply)
        }
    }

    /// Starts a reply to `messageID` in its thread, as the long-press menu's
    /// Reply does; the keyboard rises. `prefix` (a quote of the selection,
    /// from `onReplyWithSelection`) goes in at the start of the composer,
    /// before anything already typed, through the field's own editing path
    /// (the draft's formatting and mentions stay), and the caret lands after
    /// it. Returns false when the message is not in the transcript, or while
    /// a message is being edited.
    @discardableResult
    public func beginReply(toMessageID messageID: String, prefix: String? = nil) -> Bool {
        // An open edit keeps its text; the reply waits until it is saved or cancelled.
        guard editOverlay == nil, let message = store.message(id: messageID) else { return false }
        endTextSelection()
        if isSelecting { setSelecting(false) }
        enterReplyMode(for: message)
        if let prefix, !prefix.isEmpty {
            let field = composer.textView
            // The quote is plain text, whatever style the caret was in.
            field.selectedRange = NSRange(location: 0, length: 0)
            field.typingAttributes = field.baseTypingAttributes
            if let start = field.textRange(from: field.beginningOfDocument, to: field.beginningOfDocument) {
                field.replace(start, withText: prefix)
            }
            field.selectedRange = NSRange(location: (prefix as NSString).length, length: 0)
            // The composer follows its field (send button, height, draft).
            field.delegate?.textViewDidChange?(field)
        }
        return true
    }

    func endTextSelection() {
        guard let selection = textSelection else { return }
        textSelection = nil
        selection.end()
    }

    /// Touches meant for the selection (handles, the text, the loupe) stay
    /// with it instead of starting the transcript's own gestures.
    func touchBelongsToTextSelection(_ point: CGPoint) -> Bool {
        guard let selection = textSelection else { return false }
        // Grab handles hang ~20 pt past the text's ends.
        return selection.frame.insetBy(dx: -24, dy: -24).contains(point)
    }
}
#endif
