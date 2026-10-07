#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// An accessibility element whose activation runs a closure.
final class ConversationAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?
    /// Frame in the container's coordinates, re-read on every query so it
    /// follows swipe and select shifts.
    var frameProvider: (() -> CGRect)?
    /// Traits re-read on every query (select mode toggles `.selected`).
    var traitsProvider: (() -> UIAccessibilityTraits)?

    override var accessibilityTraits: UIAccessibilityTraits {
        get { traitsProvider?() ?? super.accessibilityTraits }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { frameProvider?() ?? super.accessibilityFrameInContainerSpace }
        set { super.accessibilityFrameInContainerSpace = newValue }
    }

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }
}

/// VoiceOver structure of a message row, matching Messages: the bubble is one
/// element ("Your message, text, You loved this, 3:14 AM") with Tapback,
/// Reply and Copy actions, and what sits below it ("Edited", "1 Reply",
/// "Delivered") are separate elements in reading order.
@MainActor
final class MessageCellAccessibility {
    private unowned let cell: MessageCell
    /// Elements live on the content view: UICollectionViewCell does not
    /// surface `accessibilityElements` set on the cell itself.
    private var container: UIView { cell.contentView }
    let bubble: ConversationAccessibilityElement
    let quote: ConversationAccessibilityElement
    let replies: ConversationAccessibilityElement
    let reactions: ConversationAccessibilityElement
    let failed: ConversationAccessibilityElement

    init(cell: MessageCell) {
        self.cell = cell
        bubble = ConversationAccessibilityElement(accessibilityContainer: cell.contentView)
        quote = ConversationAccessibilityElement(accessibilityContainer: cell.contentView)
        replies = ConversationAccessibilityElement(accessibilityContainer: cell.contentView)
        reactions = ConversationAccessibilityElement(accessibilityContainer: cell.contentView)
        failed = ConversationAccessibilityElement(accessibilityContainer: cell.contentView)
        quote.accessibilityTraits = .button
        replies.accessibilityTraits = .button
        reactions.accessibilityTraits = .button
        failed.accessibilityTraits = .button
        failed.accessibilityLabel = ConversationAccessibilityText.sendFailure
        reactions.accessibilityLabel = ConversationAccessibilityText.reactions
        bubble.accessibilityHint = ConversationAccessibilityText.reactHint
    }

    /// Rebuilds the element list for the row the cell now shows.
    func update(model: MessageRowModel, layout: MessageCellLayout) {
        cell.isAccessibilityElement = false
        let shifted: (CGRect) -> CGRect = { [unowned cell] rect in
            cell.shiftable.convert(rect, to: cell.contentView)
        }
        let content = layout.bubbleFrame ?? layout.emojiFrame ?? layout.imageFrames.reduce(CGRect.null) { $0.union($1) }
        bubble.frameProvider = { shifted(content.isNull ? layout.contentFrame : content) }
        bubble.accessibilityIdentifier = "conversation.bubble.\(model.message.id)"
        var elements: [Any] = []
        if let quoteModel = model.replyQuote, let frame = layout.quoteFrame {
            quote.accessibilityLabel = quoteModel.text
            quote.frameProvider = { shifted(frame) }
            elements.append(quote)
        }
        elements.append(bubble)
        if !model.reactionKinds.isEmpty, !cell.reactionBadge.isHidden {
            reactions.accessibilityValue = model.reactionKinds.map(ConversationAccessibilityText.tapbackName).joined(separator: ", ")
            reactions.frameProvider = { [unowned cell] in cell.shiftable.convert(cell.reactionBadge.frame, to: cell.contentView) }
            elements.append(reactions)
        }
        if !cell.editedLabel.isHidden { elements.append(cell.editedLabel) }
        if let frame = layout.repliesFrame, !cell.repliesLabel.isHidden {
            replies.accessibilityLabel = cell.repliesLabel.text
            replies.frameProvider = { shifted(frame) }
            elements.append(replies)
        }
        if !cell.footerLabel.isHidden { elements.append(cell.footerLabel) }
        if let frame = layout.failedBadgeFrame {
            failed.frameProvider = { frame }
            elements.append(failed)
        }
        container.accessibilityElements = elements
        // XCUITest and Accessibility Inspector read the row's label off the cell too.
        cell.accessibilityLabel = bubble.accessibilityLabel
    }
}

/// The conversation's root view. VoiceOver reads the header first, then the
/// transcript, then the composer, as in Messages; the full-screen transcript
/// otherwise ties with the header at the top-left corner and read first. A
/// modal overlay (the long-press menu) still takes over.
final class ConversationRootView: UIView {
    override var accessibilityElements: [Any]? {
        get {
            let visible = subviews.filter { !$0.isHidden && $0.alpha > 0.01 }
            if let modal = visible.last(where: { $0.accessibilityViewIsModal }) { return [modal] }
            return visible.filter { $0 is ConversationHeaderView } + visible.filter { !($0 is ConversationHeaderView) }
        }
        set { super.accessibilityElements = newValue }
    }
}

extension ConversationViewController {
    public override func loadView() {
        view = ConversationRootView()
    }

    /// Label, actions and activation for one message row. Every action routes
    /// through the same entry points as the gestures and the long-press menu.
    func configureAccessibility(_ cell: MessageCell, model: MessageRowModel) {
        let message = model.message
        let ax = cell.accessibility
        let meID = store.meID
        // An audio message speaks its duration and transcript as its content.
        var spoken = message
        if let audio = cell.audioAccessibilityText { spoken.text = audio }
        ax.bubble.accessibilityLabel = ConversationAccessibilityText.messageLabel(
            spoken,
            isOutgoing: model.isOutgoing,
            senderName: model.senderName,
            reactorName: { [weak self] id in
                id == meID ? nil : self?.store.info?.participant(id)?.name
            }
        )
        cell.accessibilityLabel = ax.bubble.accessibilityLabel
        let rowID = model.rowID
        ax.bubble.traitsProvider = { [weak self] in
            guard let self, self.isSelecting else { return [] }
            return self.selectedRowIDs.contains(rowID) ? [.selected] : []
        }
        ax.bubble.onActivate = { [weak self] in
            guard let self else { return false }
            if self.isSelecting {
                self.toggleSelection(rowID)
                return true
            }
            return self.presentAccessibleActions(rowID: rowID, mode: .menu)
        }
        ax.reactions.onActivate = { [weak self] in
            self?.presentAccessibleActions(rowID: rowID, mode: .reactionDetail) ?? false
        }
        ax.replies.onActivate = { [weak self] in
            self?.openThread(rootID: message.id)
            return true
        }
        ax.quote.onActivate = { [weak self] in
            guard let parent = message.replyToID else { return false }
            self?.openThread(rootID: parent)
            return true
        }
        ax.failed.onActivate = { [weak self] in
            self?.store.retry(rowID: rowID)
            return true
        }

        var actions: [UIAccessibilityCustomAction] = [
            UIAccessibilityCustomAction(name: ConversationAccessibilityText.tapbackAction) { [weak self] _ in
                self?.presentAccessibleActions(rowID: rowID, mode: .menu) ?? false
            },
            UIAccessibilityCustomAction(name: ConversationAccessibilityText.replyAction) { [weak self] _ in
                self?.enterReplyMode(for: message)
                return true
            },
        ]
        if message.replyCount > 0 {
            actions.append(UIAccessibilityCustomAction(name: ConversationAccessibilityText.openThreadAction) { [weak self] _ in
                self?.openThread(rootID: message.id)
                return true
            })
        }
        if !message.text.isEmpty {
            actions.append(UIAccessibilityCustomAction(name: ConversationAccessibilityText.copyAction) { _ in
                UIPasteboard.general.string = message.text
                UIAccessibility.post(notification: .announcement, argument: ConversationAccessibilityText.copiedAnnouncement)
                return true
            })
        }
        if store.canEdit(message) {
            actions.append(UIAccessibilityCustomAction(name: ConversationAccessibilityText.editAction) { [weak self] _ in
                self?.enterEditMode(for: message)
                return true
            })
        }
        if store.canUnsend(message) {
            actions.append(UIAccessibilityCustomAction(name: ConversationAccessibilityText.undoSendAction) { [weak self] _ in
                self?.store.unsend(messageID: message.id)
                return true
            })
        }
        if message.delivery?.isFailed == true {
            actions.append(UIAccessibilityCustomAction(name: ConversationAccessibilityText.tryAgainAction) { [weak self] _ in
                self?.store.retry(rowID: rowID)
                return true
            })
        }
        ax.bubble.accessibilityCustomActions = actions
    }

    /// The long-press surface, opened from VoiceOver (double tap or the
    /// Tapback action) on the row's live cell.
    private func presentAccessibleActions(rowID: String, mode: MessageActionOverlay.Mode) -> Bool {
        guard let indexPath = indexPath(for: rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model else { return false }
        presentActions(for: model, cell: cell, mode: mode)
        return true
    }

    /// Messages speaks a message that arrives in the open conversation.
    func announceArrivals(_ rows: [ConversationRow], inserted: [IndexPath], isLive: Bool) {
        guard isLive, UIAccessibility.isVoiceOverRunning else { return }
        let arrivals = inserted.compactMap { indexPath -> MessageRowModel? in
            guard indexPath.item < rows.count, case let .message(model) = rows[indexPath.item], !model.isOutgoing else { return nil }
            return model
        }
        guard let last = arrivals.last else { return }
        let text = ConversationAccessibilityText.receivedAnnouncement(senderName: last.senderName, text: last.message.text)
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }
}
#endif
