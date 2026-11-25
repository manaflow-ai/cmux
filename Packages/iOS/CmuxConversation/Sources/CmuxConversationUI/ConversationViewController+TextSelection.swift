#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// The label continues to draw effects, mentions and links. This transparent
/// text view supplies selection, handles, the loupe and the edit menu over it.
final class BubbleTextSelectionView: UITextView, UITextViewDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    let rowID: String
    let messageID: String
    /// The bubble's own text, for Copy (the overlay's copy is drawn clear).
    private let plainText: String
    var onEnd: (() -> Void)?
    /// Reply with Selection, when the host takes it (`onReplyWithSelection`).
    private let onReply: (@MainActor (ConversationSelectionReply) -> Void)?
    private var ended = false
    var messageActions: (() -> [UIMenuElement])?
    private var anchorWord: UITextRange?
    private var loupe: UITextLoupeSession?
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
        // Read as the selected words (the bubble itself reads its whole text);
        // UI tests find the selection by this identifier.
        accessibilityIdentifier = "chat.textSelection"
        addInteraction(menuInteraction)
    }

    override var accessibilityLabel: String? {
        get { Range(selectedRange, in: plainText).map { String(plainText[$0]) } ?? "" }
        set {}
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Explicit Select in a mixed-media message's attachment menu.
    func selectAllAndShowMenu() {
        _ = becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: (text as NSString).length)
        showEditMenu()
    }

    private func word(at point: CGPoint) -> UITextRange? {
        let character = characterRange(at: point)
        guard let position = character?.start ?? closestPosition(to: point) else { return nil }
        return tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward))
            ?? character
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.backward))
    }

    func beginHold(at point: CGPoint) {
        guard let range = word(at: point) else { end(); return }
        anchorWord = range
        _ = becomeFirstResponder()
        selectedTextRange = range
        loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: self)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func extendHold(to point: CGPoint) {
        guard let anchorWord, let word = word(at: point) else { return }
        let before = compare(word.start, to: anchorWord.start) == .orderedAscending
        let start = before ? word.start : anchorWord.start
        let end = before ? anchorWord.end : word.end
        selectedTextRange = textRange(from: start, to: end)
        loupe?.move(to: point, withCaretRect: caretRect(for: before ? start : end), trackingCaret: false)
    }

    func finishHold() {
        loupe?.invalidate()
        loupe = nil
        anchorWord = nil
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

    /// Reply with Selection applies only when the host accepts quoted text.
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
        UIMenu(children: suggestedActions + replyMenuElements() + (messageActions?() ?? []))
    }

    /// The menu UIKit shows itself after the handles move.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions + replyMenuElements() + (messageActions?() ?? []))
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Tapping the selection away (or any collapse) ends it, as in Messages.
        guard anchorWord == nil, selectedRange.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selectedRange.length == 0 else { return }
            self.end()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { end() }
        return resigned
    }

    func end() {
        guard !ended else { return }
        ended = true
        loupe?.invalidate()
        loupe = nil
        onEnd?()
    }
}

extension ConversationViewController {
    func canSelectText(in cell: MessageCell) -> Bool {
        cell.selectableLabel != nil
    }

    /// The finger location is in transcript coordinates. An explicit Select
    /// command from the attachment menu can still request the entire message.
    func beginTextSelection(rowID: String, at point: CGPoint? = nil) {
        endTextSelection()
        guard let indexPath = indexPath(for: rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model, let label = cell.selectableLabel else { return }
        let attributed: NSAttributedString
        if label === cell.emojiLabel {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = label.textAlignment
            attributed = NSAttributedString(string: model.message.text, attributes: [.font: cell.emojiLabel.font as UIFont, .paragraphStyle: paragraph])
        } else if let text = label.attributedText {
            attributed = text
        } else {
            return
        }
        composer.textView.resignFirstResponder()
        let selection = BubbleTextSelectionView(
            rowID: rowID,
            messageID: model.message.id,
            text: attributed,
            tint: model.isOutgoing && label === cell.textLabel ? .white : .systemBlue,
            onReply: replyWithSelectionHandler()
        )
        selection.messageActions = { [weak self, weak cell] in
            guard let self, let cell, let model = cell.model, model.rowID == rowID else { return [] }
            var actions = self.messageMenuItems(for: model, cell: cell, forSelection: true).map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.symbol), attributes: item.isDestructive ? .destructive : []) { [weak self] _ in
                    self?.endTextSelection()
                    item.handler()
                }
            }
            let tapback = String(localized: "conversation.photoViewer.tapback", defaultValue: "Tapback", bundle: .module)
            actions.append(UIAction(title: tapback, image: UIImage(systemName: "face.smiling")) { [weak self, weak cell] _ in
                guard let self, let cell, let model = cell.model, model.rowID == rowID else { return }
                self.endTextSelection()
                self.presentActions(for: model, cell: cell, mode: .tapbacks)
            })
            return actions
        }
        selection.frame = label.frame
        selection.onEnd = { [weak self, weak selection, weak cell] in
            guard let selection else { return }
            if self?.textSelection === selection { self?.textSelection = nil }
            if cell?.activeTextSelection === selection { cell?.activeTextSelection = nil }
            if let row = cell?.contentView, let elements = row.accessibilityElements {
                row.accessibilityElements = elements.filter { ($0 as AnyObject) !== selection }
            }
            selection.removeFromSuperview()
        }
        label.superview?.insertSubview(selection, aboveSubview: label)
        cell.activeTextSelection = selection
        // The row's accessibility list is explicit (MessageCellAccessibility): the live selection
        // joins it, or VoiceOver and UI tests never see it (fleet simulator step 56d846f0a93209464c930cb8).
        cell.contentView.accessibilityElements = (cell.contentView.accessibilityElements ?? []) + [selection]
        textSelection = selection
        if let point {
            selection.beginHold(at: selection.convert(point, from: collectionView))
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
        return selection.bounds.insetBy(dx: -24, dy: -24).contains(selection.convert(point, from: collectionView))
    }
}
#endif
