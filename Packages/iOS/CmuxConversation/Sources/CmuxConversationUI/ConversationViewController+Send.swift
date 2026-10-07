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
        if replyTarget != nil { exitReplyMode(settling: false) }
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

        // Measured on iOS 26 Messages: photos never shrink to the card's
        // thumbnails. The stack rises at its final size from where the card
        // showed the first photo, fading in, on a critically damped spring.
        var imageFlights: [UIView] = []
        let stackTop = cellLayout.imageFrames.first.map { $0.minY + cellOrigin.y }
        let rise = stackTop.map { max(0, flight.fieldFrame.minY + 6 - $0) } ?? 0
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
            imageView.transform = CGAffineTransform(translationX: 0, y: rise)
            imageView.alpha = 0
            container.addSubview(imageView)
            imageFlights.append(imageView)
        }

        var bubbleFlight: (bubble: BubbleBackgroundView, clip: UIView, label: UILabel, from: CGRect, to: CGRect, textFrom: CGRect, textTo: CGRect)?
        if let bubbleFrame = cellLayout.bubbleFrame, let textFrame = cellLayout.textFrame {
            let bubble = BubbleBackgroundView()
            bubble.side = .trailing
            bubble.hasTail = model.showsTail
            bubble.fillColor = ConversationTheme.outgoingBubble
            let label = UILabel()
            label.numberOfLines = 0
            label.attributedText = layoutCache.attributedText(for: model)
            // The text rides in a clip that moves with the bubble, so a draft
            // taller than the field shows the same lines the composer showed.
            let clip = UIView()
            clip.clipsToBounds = true
            clip.isUserInteractionEnabled = false
            clip.addSubview(label)
            container.addSubview(bubble)
            container.addSubview(clip)
            let to = bubbleFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let textTo = textFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            // Start as the whole composer field, text where it was typed.
            let from = CGRect(
                x: flight.fieldFrame.minX,
                y: flight.fieldFrame.maxY - max(ConversationTheme.composerMinHeight, min(flight.fieldFrame.height, to.height)),
                width: flight.fieldFrame.width + ConversationTheme.tailWidth,
                height: max(ConversationTheme.composerMinHeight, min(flight.fieldFrame.height, to.height))
            )
            // Bottom-aligned at the start: a scrolled draft showed its end, and
            // a short one lands at the same spot as top alignment.
            let textFrom = CGRect(
                x: flight.textFrame.minX,
                y: from.maxY - ConversationTheme.bubbleVerticalPadding - textTo.height + 1,
                width: textTo.width,
                height: textTo.height
            )
            bubbleFlight = (bubble, clip, label, from, to, textFrom, textTo)
        }

        UIView.performWithoutAnimation {
            if let flight = bubbleFlight {
                flight.bubble.frame = flight.from
                flight.bubble.layoutIfNeeded()
                flight.clip.frame = flight.from
                flight.label.frame = flight.textFrom.offsetBy(dx: -flight.from.minX, dy: -flight.from.minY)
            }
        }

        // Main motion ~0.35 s with a small overshoot, settled by ~0.7 s. The
        // transaction's completion lands the flight however the animation ends.
        activeFlights[rowID] = container
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.landFlight(rowID: rowID)
        }
        // Frame fit of Messages' 2-photo send: residual offset follows
        // (1 + wt)e^-wt with w ~ 23/s (0.27 s response, no overshoot); opacity
        // reaches ~0.4 by 67 ms and ~0.9 by 200 ms.
        UIView.animate(springDuration: 0.27, bounce: 0, options: [.allowUserInteraction]) {
            for image in imageFlights { image.transform = .identity }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            for image in imageFlights { image.alpha = 1 }
        }
        UIView.animate(withDuration: 0.8, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            if let flight = bubbleFlight {
                flight.bubble.frame = flight.to
                flight.bubble.layoutIfNeeded()
                flight.clip.frame = flight.to
                flight.label.frame = flight.textTo.offsetBy(dx: -flight.to.minX, dy: -flight.to.minY)
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
    /// Messages-style edit: the transcript blurs and the message becomes an
    /// editable field in its bubble's place (grey X reverts, blue checkmark
    /// saves). The composer and its draft stay untouched.
    func enterEditMode(for message: ConversationMessage) {
        guard editOverlay == nil, let indexPath = indexPath(for: message.rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { return }
        if replyTarget != nil { exitReplyMode() }
        editingMessageID = message.id
        revealRowID = message.rowID
        let overlay = MessageEditOverlay(text: message.text)
        overlay.onSave = { [weak self] text in
            self?.store.edit(messageID: message.id, text: text)
            self?.exitEditMode()
        }
        overlay.onCancel = { [weak self] in self?.exitEditMode() }
        editOverlay = overlay
        overlay.install(in: view, sourceFrame: cell.convert(cell.liftedContentFrame, to: view), topInset: header.frame.maxY)
    }

    func exitEditMode() {
        editingMessageID = nil
        revealRowID = nil
        editOverlay?.dismiss {}
        editOverlay = nil
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
