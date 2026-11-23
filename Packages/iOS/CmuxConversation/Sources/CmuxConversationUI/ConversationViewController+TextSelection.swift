#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// In-place text selection in a bubble, with grab handles and the system
/// edit menu (Copy, Look Up, Translate, more). A hold on a bubble's text
/// selects the word under the finger, as text does across iOS (Leo,
/// 2026-11-23: "just hold and it should highlight text as normal"); the
/// menu's "Select" selects the bubble's whole text, as Messages does.
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
    /// The message's own actions (tapbacks, Reply, Edit, More…), the menu a
    /// hold opened before it selected text: the edit menu's last item.
    var onMessageActions: (() -> Void)?
    /// The word the hold selected: a drag from it keeps it selected.
    private var anchorRange: NSRange?
    private var ended = false
    /// UITextView keeps its own edit menu private; this one gathers the same
    /// system actions from the responder chain: Copy, Look Up, Translate,
    /// Share, then Reply with Selection and Message Actions… when the host
    /// offers them.
    private lazy var menuInteraction = UIEditMenuInteraction(delegate: self)

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
        // Read as the selected words (the bubble itself reads its whole
        // text); UI tests find it by this identifier.
        accessibilityIdentifier = "chat.textSelection"
        accessibilityLabel = String(localized: "conversation.selection.label", defaultValue: "Selected text", bundle: .module)
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

    /// Selects the word at `point` (in this view) and, with `showsMenu`, shows
    /// the edit menu. A point on blank space takes the nearest word.
    func selectWord(at point: CGPoint, showsMenu: Bool = true) {
        _ = becomeFirstResponder()
        layoutIfNeeded()
        guard let position = closestPosition(to: point),
              let range = Self.wordRange(at: position, in: tokenizer),
              !range.isEmpty else { return selectAllAndShowMenu() }
        selectedTextRange = range
        anchorRange = selectedRange
        if showsMenu { showEditMenu() }
    }

    /// The word around `position`, else the one before or after it.
    private static func wordRange(at position: UITextPosition, in tokenizer: any UITextInputTokenizer) -> UITextRange? {
        let backward = UITextDirection(rawValue: UITextStorageDirection.backward.rawValue)
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        return tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: forward)
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: backward)
            ?? tokenizer.position(from: position, toBoundary: .word, inDirection: forward).flatMap { end in
                tokenizer.rangeEnclosingPosition(end, with: .word, inDirection: backward)
            }
    }

    /// The held finger moved to `point` (in this view): the selection runs
    /// from the held word to the character under it, either way.
    func extendSelection(to point: CGPoint) {
        guard let anchor = anchorRange, let position = closestPosition(to: point) else { return }
        menuInteraction.dismissMenu()
        let offset = self.offset(from: beginningOfDocument, to: position)
        let lower = min(anchor.location, offset)
        let upper = max(NSMaxRange(anchor), offset)
        guard upper > lower else { return }
        selectedRange = NSRange(location: lower, length: upper - lower)
    }

    /// The selected words, as assistive technologies and UI tests read them.
    override var accessibilityValue: String? {
        get {
            guard selectedRange.length > 0, let range = Range(selectedRange, in: plainText) else { return nil }
            return String(plainText[range])
        }
        set {}
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

    /// The message's actions, last in the edit menu, when the host offers them.
    private func messageActionElements() -> [UIMenuElement] {
        guard onMessageActions != nil else { return [] }
        let title = String(localized: "conversation.menu.messageActions", defaultValue: "Message Actions…", bundle: .module)
        return [UIAction(title: title, image: UIImage(systemName: "ellipsis.circle")) { [weak self] _ in
            self?.onMessageActions?()
        }]
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: replyMenuElements() + suggestedActions + messageActionElements())
    }

    /// The menu UIKit shows itself after the handles move.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let extra = (replyMenuElements(), messageActionElements())
        guard !extra.0.isEmpty || !extra.1.isEmpty else { return nil }
        return UIMenu(children: extra.0 + suggestedActions + extra.1)
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

    /// Selects text in the row's bubble: the word at `point` (in the
    /// collection view) when given, else the whole text with its menu.
    func beginTextSelection(rowID: String, wordAt point: CGPoint? = nil, showsMenu: Bool = true) {
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
        selection.onMessageActions = { [weak self] in
            self?.endTextSelection()
            guard let self, let indexPath = self.indexPath(for: rowID),
                  let cell = self.collectionView.cellForItem(at: indexPath) as? MessageCell,
                  let model = cell.model else { return }
            self.presentActions(for: model, cell: cell, mode: .menu)
        }
        collectionView.addSubview(selection)
        textSelection = selection
        if let point {
            selection.selectWord(at: collectionView.convert(point, to: selection), showsMenu: showsMenu)
        } else {
            selection.selectAllAndShowMenu()
        }
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
