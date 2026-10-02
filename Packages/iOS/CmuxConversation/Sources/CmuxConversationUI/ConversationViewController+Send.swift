#if canImport(UIKit)
import CmuxConversationCore
import UIKit

extension ConversationViewController: ConversationComposerViewDelegate {
    func composerDidChangeText(_ composer: ConversationComposerView) {
        store.composerTextChanged(isEmpty: composer.text.isEmpty)
    }

    func composerDidChangeHeight(_ composer: ConversationComposerView) {
        composerHeightConstraint?.constant = composer.preferredHeight
        // Growth applies in the same frame as the edit (no animation); a
        // collapse after send is driven by the composer's own spring.
        view.layoutIfNeeded()
    }

    func composerDidTapPlus(_ composer: ConversationComposerView) {
        presentAppsMenu()
    }

    func composerDidTapSend(_ composer: ConversationComposerView) {
        if let messageID = editingMessageID {
            store.edit(messageID: messageID, text: composer.text)
            exitEditMode()
            return
        }
        let text = composer.text
        let attachments = composer.attachments
        let fieldFrame = composer.fieldFrame(in: view)
        let textFrame = composer.textFrame(in: view)
        let replyTo = replyTarget?.id
        let images = attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width * attachment.image.scale), height: Int(attachment.image.size.height * attachment.image.scale), mimeType: attachment.mimeType)
        }
        // Create the flight before the row exists so the row inserts hidden.
        let flight = SendFlight(text: text, attachments: attachments.map(\.image), fieldFrame: fieldFrame, textFrame: textFrame)
        pendingFlight = flight
        composer.clearAfterSend()
        photoDrawer?.clearSelection()
        pickedAssets = [:]
        guard let rowID = store.send(text: text, images: images, replyToID: replyTo) else {
            pendingFlight = nil
            return
        }
        pendingFlight = nil
        if replyTarget != nil { exitReplyMode() }
        launch(flight, rowID: rowID)
    }

    /// Animates a bubble from the composer field into its slot. The real
    /// cell stays hidden until the flight lands, so exactly one copy of the
    /// text is ever visible.
    func launch(_ flight: SendFlight, rowID: String) {
        guard let index = indexPath(for: rowID)?.item,
              case let .message(model) = rows[index],
              let cellFrame = layout.frame(at: index) else {
            flyingRowIDs.remove(rowID)
            return
        }
        let cellLayout = layoutCache.layout(for: model, width: collectionView.bounds.width, margin: layoutMargin)
        // Final position uses the model (post-animation) scroll offset.
        let cellOrigin = CGPoint(x: cellFrame.minX, y: cellFrame.minY - collectionView.bounds.minY + collectionView.frame.minY)
        let container = UIView(frame: view.bounds)
        container.isUserInteractionEnabled = false
        view.insertSubview(container, belowSubview: header)

        var pieces: [(view: UIView, from: CGRect, to: CGRect)] = []
        for (offset, imageFrame) in cellLayout.imageFrames.enumerated() where offset < flight.attachments.count {
            let imageView = UIImageView(image: flight.attachments[offset])
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = ConversationTheme.bubbleCornerRadius
            imageView.layer.cornerCurve = .continuous
            let to = imageFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let from = CGRect(x: flight.fieldFrame.minX + 12, y: flight.fieldFrame.minY + 8, width: min(flight.fieldFrame.width - 24, to.width * 0.5), height: min(120, to.height * 0.5))
            container.addSubview(imageView)
            pieces.append((imageView, from, to))
        }

        var bubbleFlight: (bubble: BubbleBackgroundView, label: UILabel, from: CGRect, to: CGRect, textFrom: CGRect, textTo: CGRect)?
        if let bubbleFrame = cellLayout.bubbleFrame, let textFrame = cellLayout.textFrame {
            let bubble = BubbleBackgroundView()
            bubble.side = .trailing
            bubble.hasTail = model.showsTail
            bubble.fillColor = ConversationTheme.outgoingBubble
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = layoutCache.attributedText(for: model)
            container.addSubview(bubble)
            container.addSubview(label)
            let to = bubbleFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let textTo = textFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            // Start as the whole composer field, text where it was typed.
            let from = CGRect(
                x: flight.fieldFrame.minX,
                y: flight.fieldFrame.maxY - max(ConversationTheme.composerMinHeight, min(flight.fieldFrame.height, to.height)),
                width: flight.fieldFrame.width + ConversationTheme.tailWidth,
                height: max(ConversationTheme.composerMinHeight, min(flight.fieldFrame.height, to.height))
            )
            let textFrom = CGRect(x: flight.textFrame.minX, y: from.minY + ConversationTheme.bubbleVerticalPadding - 1, width: textTo.width, height: textTo.height)
            bubbleFlight = (bubble, label, from, to, textFrom, textTo)
        }

        UIView.performWithoutAnimation {
            for piece in pieces { piece.view.frame = piece.from }
            if let flight = bubbleFlight {
                flight.bubble.frame = flight.from
                flight.bubble.layoutIfNeeded()
                flight.label.frame = flight.textFrom
            }
        }

        // Main motion ~0.35 s with a small overshoot, settled by ~0.7 s. The
        // transaction's completion lands the flight however the animation ends.
        activeFlights[rowID] = container
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.landFlight(rowID: rowID)
        }
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            for piece in pieces { piece.view.frame = piece.to }
            if let flight = bubbleFlight {
                flight.bubble.frame = flight.to
                flight.bubble.layoutIfNeeded()
                flight.label.frame = flight.textTo
            }
        }
        CATransaction.commit()
    }
}

extension ConversationViewController {
    /// Removes a flight's overlay and reveals its real row. Idempotent; runs
    /// when the flight's animation ends, the row reshapes, or the reader scrolls.
    func landFlight(rowID: String) {
        activeFlights.removeValue(forKey: rowID)?.removeFromSuperview()
        flyingRowIDs.remove(rowID)
        if let index = indexPath(for: rowID), let cell = collectionView.cellForItem(at: index) {
            cell.contentView.alpha = 1
        }
    }

    func landAllFlights() {
        for rowID in Array(activeFlights.keys) { landFlight(rowID: rowID) }
    }
}

extension ConversationViewController {
    /// Messages-style edit: the message's text moves into the composer and
    /// the send button becomes a checkmark; X cancels.
    func enterEditMode(for message: ConversationMessage) {
        if replyTarget != nil { exitReplyMode() }
        editingMessageID = message.id
        composer.isEditMode = true
        composer.text = message.text
        header.setTrailingMode(.close, animated: true)
        composer.textView.becomeFirstResponder()
    }

    func exitEditMode() {
        editingMessageID = nil
        composer.isEditMode = false
        composer.clearAfterSend()
        header.setTrailingMode(isSelecting || replyTarget != nil ? .close : .action, animated: true)
    }
}

/// What the composer held at the moment of sending.
struct SendFlight {
    var text: String
    var attachments: [UIImage]
    var fieldFrame: CGRect
    var textFrame: CGRect
}
#endif
