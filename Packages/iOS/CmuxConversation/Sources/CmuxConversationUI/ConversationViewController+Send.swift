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

        // Images fly at their final size and shape (tail included), scaled
        // down to the composer thumbnail, so the tail never pops in late.
        var imageFlights: [(view: UIView, start: CGAffineTransform)] = []
        for (offset, imageFrame) in cellLayout.imageFrames.enumerated() where offset < flight.attachments.count {
            let imageView = UIImageView(image: flight.attachments[offset])
            imageView.contentMode = .scaleAspectFill
            let to = imageFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            imageView.frame = to
            let tailed = model.showsTail && offset == cellLayout.imageFrames.count - 1 && model.message.text.isEmpty
            var maskRect = imageView.bounds
            if tailed { maskRect.size.height -= ConversationTheme.tailDrop }
            let mask = CAShapeLayer()
            mask.path = BubbleShape.path(in: maskRect, side: .trailing, tail: tailed).cgPath
            imageView.layer.mask = mask
            let from = CGRect(x: flight.fieldFrame.minX + 12, y: flight.fieldFrame.minY + 8, width: min(flight.fieldFrame.width - 24, 120 * CGFloat(flight.attachments[offset].size.width / max(1, flight.attachments[offset].size.height))), height: 120)
            let scale = min(from.width / to.width, from.height / to.height)
            let start = CGAffineTransform(translationX: from.midX - to.midX, y: from.midY - to.midY).scaledBy(x: scale, y: scale)
            imageView.transform = start
            container.addSubview(imageView)
            imageFlights.append((imageView, start))
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
        // Images travel farther from the card and take ~0.5 s (A20/A21).
        UIView.animate(withDuration: 1.1, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            for image in imageFlights { image.view.transform = .identity }
        }
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
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
        revealRowID = message.rowID
        composer.isEditMode = true
        composer.text = message.text
        header.setTrailingMode(.close, animated: true)
        composer.textView.becomeFirstResponder()
    }

    func exitEditMode() {
        editingMessageID = nil
        revealRowID = nil
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
