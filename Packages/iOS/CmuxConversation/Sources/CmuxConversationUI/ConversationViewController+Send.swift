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

        // Text and emoji fly in a mover parked at the final frame. Measured
        // against Messages (iOS 26): the trailing edge stays pinned while the
        // field's width collapses to the bubble's in ~0.15 s, the whole body
        // dips to ~0.77 scale and back over ~0.4 s, and the rise is a 0.5 s
        // response spring (damping 0.82) that settles in ~0.39 s.
        var textFlight: SendFlightMotion?
        if let bubbleFrame = cellLayout.bubbleFrame, let textFrame = cellLayout.textFrame {
            let to = bubbleFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let textTo = textFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
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
            let mover = UIView(frame: to)
            mover.isUserInteractionEnabled = false
            mover.addSubview(bubble)
            mover.addSubview(clip)
            container.addSubview(mover)
            // Start as the composer field (tail included), trailing edge at
            // the bubble's, bottom-aligned with the field.
            let height = max(ConversationTheme.composerMinHeight, min(flight.fieldFrame.height, to.height))
            let from = CGRect(x: flight.fieldFrame.minX, y: flight.fieldFrame.maxY - height, width: max(to.width, to.maxX - flight.fieldFrame.minX), height: height)
            // Text starts where it was typed: leading edge at the typed
            // glyphs, bottom-aligned (a scrolled draft showed its end).
            let textFrom = CGRect(
                x: flight.textFrame.minX,
                y: from.maxY - ConversationTheme.bubbleVerticalPadding - textTo.height + 1,
                width: textTo.width,
                height: textTo.height
            )
            textFlight = SendFlightMotion(
                mover: mover, body: [bubble, clip], label: label,
                startCenterY: from.midY, endCenterY: to.midY,
                bodyFrom: CGRect(x: from.minX - to.minX, y: (to.height - from.height) / 2, width: from.width, height: from.height),
                bodyTo: CGRect(origin: .zero, size: to.size),
                labelFrom: textFrom.offsetBy(dx: -from.minX, dy: -from.minY),
                labelTo: textTo.offsetBy(dx: -to.minX, dy: -to.minY),
                fieldHeight: flight.fieldFrame.height
            )
        } else if let emojiFrame = cellLayout.emojiFrame {
            // Emoji-only sends fly bare, growing from the composer's text
            // size to the large emoji.
            let to = emojiFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let label = UILabel()
            label.font = .systemFont(ofSize: ConversationTheme.emojiOnlyFontSize)
            label.numberOfLines = 0
            label.text = model.message.text
            let mover = UIView(frame: to)
            mover.isUserInteractionEnabled = false
            mover.addSubview(label)
            container.addSubview(mover)
            let ratio = ConversationTheme.bodyFont.pointSize / ConversationTheme.emojiOnlyFontSize
            let start = CGSize(width: to.width * ratio, height: to.height * ratio)
            let lineMidY = flight.textFrame.minY + ConversationTheme.bubbleVerticalPadding + ConversationTheme.bodyFont.lineHeight / 2
            let from = CGRect(x: flight.textFrame.minX, y: lineMidY - start.height / 2, width: start.width, height: start.height)
            textFlight = SendFlightMotion(
                mover: mover, body: [label], label: nil,
                startCenterY: from.midY, endCenterY: to.midY,
                bodyFrom: CGRect(x: from.minX - to.minX, y: (to.height - from.height) / 2, width: from.width, height: from.height),
                bodyTo: CGRect(origin: .zero, size: to.size),
                labelFrom: .zero, labelTo: .zero,
                fieldHeight: flight.fieldFrame.height
            )
        }

        UIView.performWithoutAnimation { textFlight?.applyStart() }

        // The transaction's completion lands the flight however it ends.
        activeFlights[rowID] = container
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.landFlight(rowID: rowID)
        }
        // Images travel farther from the card and take ~0.5 s (A20/A21).
        UIView.animate(withDuration: 1.1, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            for image in imageFlights { image.view.transform = .identity }
        }
        textFlight?.animate()
        CATransaction.commit()
    }
}

extension ConversationViewController {
    /// Removes a flight's overlay and reveals its real row. Idempotent; runs
    /// when the flight's animation ends, the row reshapes, or the reader scrolls.
    func landFlight(rowID: String) {
        activeFlights.removeValue(forKey: rowID)?.removeFromSuperview()
        flyingRowIDs.remove(rowID)
        if let index = indexPath(for: rowID), let cell = collectionView.cellForItem(at: index) as? MessageCell {
            cell.setFlightHidden(false)
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

/// One text or emoji send flight: a mover parked at the final frame whose
/// center rises on a spring while its body (bubble and text clip) collapses
/// from the composer field into the mover's bounds.
struct SendFlightMotion {
    let mover: UIView
    let body: [UIView]
    let label: UILabel?
    let startCenterY: CGFloat
    let endCenterY: CGFloat
    let bodyFrom: CGRect
    let bodyTo: CGRect
    let labelFrom: CGRect
    let labelTo: CGRect
    /// The composer field's height at send, which sets the dip depth.
    let fieldHeight: CGFloat

    func applyStart() {
        mover.center.y = startCenterY
        mover.alpha = 0.7
        for view in body {
            view.frame = bodyFrom
            view.layoutIfNeeded()
        }
        label?.frame = labelFrom
    }

    /// Scale about the trailing edge, where Messages pins the bubble.
    private func trailingScale(_ scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: mover.bounds.width * (1 - scale) / 2, y: 0).scaledBy(x: scale, y: scale)
    }

    func animate() {
        let options: UIView.AnimationOptions = [.allowUserInteraction]
        UIView.animate(springDuration: 0.5, bounce: 0.18, initialSpringVelocity: 0, delay: 0.015, options: options) {
            mover.center.y = endCenterY
        }
        // Width collapse in ~0.14 s, between linear and ease-out like
        // Messages; a cubic curve (not a spring) so the bubble's path
        // animation follows its bounds.
        let collapse = UIViewPropertyAnimator(duration: 0.14, controlPoint1: CGPoint(x: 0.2, y: 0.3), controlPoint2: CGPoint(x: 0.6, y: 1)) {
            for view in body {
                view.frame = bodyTo
                view.layoutIfNeeded()
            }
            label?.frame = labelTo
        }
        collapse.isUserInteractionEnabled = true
        collapse.startAnimation()
        UIView.animate(withDuration: 0.14, delay: 0, options: options.union(.curveEaseOut)) {
            mover.alpha = 1
        }
        // Scale dip: ChatKit's glass send (CASpringAnimation(SendAnimation)),
        // an additive spring down to a factor set by the field's height and
        // one back up from 0.185 s. Messages runs them ~1.15x faster than
        // their nominal time (measured), settling the dip by ~0.4 s.
        let factor = Self.scaleDownFactor(fieldHeight: fieldHeight)
        let now = mover.layer.convertTime(CACurrentMediaTime(), from: nil)
        for (target, stiffness, delay, key) in [(factor, 310.0, 0.0, "sendDipDown"), (1 / factor, 320.0, 0.185, "sendDipUp")] {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 2
            spring.stiffness = stiffness
            spring.damping = 38
            spring.isAdditive = true
            spring.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.toValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(trailingScale(target)))
            spring.duration = spring.settlingDuration
            spring.speed = 1.15
            spring.beginTime = now + delay / 1.15
            spring.fillMode = .both
            // Both stay until the flight lands; dropping one early would
            // leave the other's scale applied.
            spring.isRemovedOnCompletion = false
            mover.layer.add(spring, forKey: key)
        }
    }

    /// ChatKit's `_ck_scaleDownFactorForEntryViewSize:` (iOS 26), sampled:
    /// 0.70 for a one-line field rising to 0.90 for a 300 pt draft.
    static func scaleDownFactor(fieldHeight: CGFloat) -> CGFloat {
        let samples: [(CGFloat, CGFloat)] = [(36, 0.7), (50, 0.708), (60, 0.7163), (80, 0.7329), (100, 0.7494), (120, 0.766), (150, 0.7908), (200, 0.8321), (250, 0.8735), (300, 0.9)]
        guard fieldHeight > samples[0].0 else { return samples[0].1 }
        for (lower, upper) in zip(samples, samples.dropFirst()) where fieldHeight <= upper.0 {
            return lower.1 + (upper.1 - lower.1) * (fieldHeight - lower.0) / (upper.0 - lower.0)
        }
        return 0.9
    }
}

extension MessageCell {
    /// While its send flight is in the air the row hides only what the
    /// flight draws (bubble, text, emoji, images) and its status, so a
    /// reply's quote and the sender name stay in place.
    func setFlightHidden(_ hidden: Bool) {
        contentView.alpha = 1
        let alpha: CGFloat = hidden ? 0 : 1
        let flown: [UIView] = [bubble, textLabel, emojiLabel, footerLabel] + imageViews
        for view in flown {
            view.alpha = alpha
        }
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
