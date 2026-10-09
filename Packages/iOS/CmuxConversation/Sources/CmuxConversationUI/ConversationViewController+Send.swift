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
        // While recording, "+" is the cancel button.
        if audioComposer.isActive {
            audioComposer.cancel()
            return
        }
        presentAppsMenu()
    }

    func composerDidTapSend(_ composer: ConversationComposerView) {
        if sendLaterIfNeeded(composer) { return }
        let effect = effects.pendingSendEffect
        effects.pendingSendEffect = nil
        let text = composer.text
        let mentions = composer.mentions
        let textRuns = composer.textRuns
        let attachments = composer.attachments
        let fieldFrame = composer.fieldFrame(in: view)
        let textFrame = composer.textFrame(in: view)
        let replyTo = replyTarget?.id
        let linkPreview = composer.linkPreview.sendablePreview
        let images = attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width * attachment.image.scale), height: Int(attachment.image.size.height * attachment.image.scale), mimeType: attachment.mimeType)
        }
        // Create the flight before the row exists so the row inserts hidden.
        let flight = SendFlight(text: text, attachments: attachments.map(\.image), fieldFrame: fieldFrame, textFrame: textFrame)
        // A bubble effect replaces the flight: the bubble makes its entrance in place.
        let flies = effect?.kind != .bubble
        pendingFlight = flies ? flight : nil
        composer.clearAfterSend()
        photoDrawer?.clearSelection()
        pickedAssets = [:]
        guard let rowID = store.send(text: text, images: images, replyToID: replyTo, mentions: mentions, textRuns: textRuns, linkPreview: linkPreview, effect: effect) else {
            pendingFlight = nil
            return
        }
        pendingFlight = nil
        if replyTarget != nil { exitReplyMode(settling: false) }
        if flies { launch(flight, rowID: rowID) }
        if effect != nil { playSentEffect(rowID: rowID) }
        // The send button leaves with the text; VoiceOver stays in the field.
        UIAccessibility.post(notification: .layoutChanged, argument: composer.textView)
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
        // Over the composer: Messages' bubble leaves from behind a clear
        // send-animation glass (private) that only lenses its rim; under our
        // public glass it would turn frosted, so it flies on top.
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

        // Text and emoji fly in a mover parked at the final frame, on
        // ChatKit's throw (identical on iOS 26 and 27; see SendFlightMotion):
        // the trailing edge stays pinned while the field's width collapses
        // to the bubble's, the body dips and recovers, and the center rises.
        var textFlight: SendFlightMotion?
        if let bubbleFrame = cellLayout.bubbleFrame, let textFrame = cellLayout.textFrame {
            let to = bubbleFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let textTo = textFrame.offsetBy(dx: cellOrigin.x, dy: cellOrigin.y)
            let bubble = BubbleBackgroundView()
            bubble.side = .trailing
            bubble.hasTail = model.showsTail
            bubble.fillColor = ConversationTheme.outgoingBubble
            // The landed bubble's screen-fixed gradient, sampled where it lands,
            // so the color doesn't change at the hand-off to the cell.
            bubble.screenGradient = ConversationTheme.iMessageGradient
            let label = ConversationEffectLabel()
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
                mover: mover, body: [bubble, clip], fill: bubble, label: label,
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
            let landedSize = ConversationTheme.emojiOnlyFontSize(count: MessageCellLayout.emojiCount(model.message.text))
            label.font = .systemFont(ofSize: landedSize)
            label.numberOfLines = 0
            label.text = model.message.text
            let mover = UIView(frame: to)
            mover.isUserInteractionEnabled = false
            mover.addSubview(label)
            container.addSubview(mover)
            // The composer already shows an emoji-only draft large (same sizes).
            let draftSize = ConversationComposerView.emojiPointSize(for: model.message.text) ?? ConversationTheme.bodyFont.pointSize
            let ratio = draftSize / landedSize
            let start = CGSize(width: to.width * ratio, height: to.height * ratio)
            let lineMidY = flight.textFrame.minY + ConversationTheme.bubbleVerticalPadding + ConversationTheme.bodyFont.lineHeight / 2
            let from = CGRect(x: flight.textFrame.minX, y: lineMidY - start.height / 2, width: start.width, height: start.height)
            textFlight = SendFlightMotion(
                mover: mover, body: [label], fill: nil, label: nil,
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
        // Frame fit of Messages' 2-photo send: residual offset follows
        // (1 + wt)e^-wt with w ~ 23/s (0.27 s response, no overshoot); opacity
        // reaches ~0.4 by 67 ms and ~0.9 by 200 ms.
        UIView.animate(springDuration: 0.27, bounce: 0, options: [.allowUserInteraction]) {
            for image in imageFlights { image.transform = .identity }
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            for image in imageFlights { image.alpha = 1 }
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
            // The in-place field edits plain text; formatting on characters the
            // edit left alone carries over.
            self?.store.edit(messageID: message.id, text: text, textRuns: ConversationRichText.carried(message.textRuns, from: message.text, to: text))
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
        header.setTrailingMode(isSelecting ? .cancel : (replyTarget != nil ? .close : .action), animated: true)
    }
}

/// One text or emoji send flight: a mover parked at the final frame whose
/// center rises on a spring while its body (bubble and text clip) collapses
/// from the composer field into the mover's bounds.
///
/// Timing is ChatKit's throw, logged from Messages on iOS 26.5 and 27.0
/// (the same on both): the throw view's position springs (mass 1,
/// stiffness 141.759, damping 17.35), y starting 0.055 s after x; the
/// balloon's bounds take 0.2 s on (0.542, 0, 0.58, 1); its fill fades from
/// 0.6 opacity over 0.2 s on (0.42, 0, 1, 1) while the text stays opaque;
/// and two additive scale springs dip and recover it.
struct SendFlightMotion {
    let mover: UIView
    let body: [UIView]
    /// The bubble whose fill fades in (nil for a bare emoji).
    let fill: UIView?
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
        if let fill {
            fill.alpha = 0.6
        } else {
            mover.alpha = 0.7
        }
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
        let rise = UIViewPropertyAnimator(duration: 0, timingParameters: UISpringTimingParameters(mass: 1, stiffness: 141.759, damping: 17.35, initialVelocity: .zero))
        rise.addAnimations { mover.center.y = endCenterY }
        rise.isUserInteractionEnabled = true
        rise.startAnimation(afterDelay: 0.055)
        // A cubic curve (not a spring) so the bubble's path animation
        // follows its bounds.
        let collapse = UIViewPropertyAnimator(duration: 0.2, controlPoint1: CGPoint(x: 0.542, y: 0), controlPoint2: CGPoint(x: 0.58, y: 1)) {
            for view in body {
                view.frame = bodyTo
                view.layoutIfNeeded()
            }
            label?.frame = labelTo
        }
        collapse.isUserInteractionEnabled = true
        collapse.startAnimation()
        let fade = UIViewPropertyAnimator(duration: 0.2, controlPoint1: CGPoint(x: 0.42, y: 0), controlPoint2: CGPoint(x: 1, y: 1)) {
            fill?.alpha = 1
            mover.alpha = 1
        }
        fade.isUserInteractionEnabled = true
        fade.startAnimation()
        // Scale dip: ChatKit's scaleDown spring to a factor set by the
        // field's height, and scaleUp back from 0.185 s; additive, so they
        // compose.
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
            spring.beginTime = now + delay
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
