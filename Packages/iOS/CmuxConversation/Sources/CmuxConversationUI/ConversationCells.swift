#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// One message: optional sender name, reply quote, images, text bubble or
/// large emoji, tapback badge, avatar, and footers. Frames come from
/// `MessageCellLayout`; the cell only places views.
final class MessageCell: UICollectionViewCell {
    static let reuseID = "message"

    let senderLabel = UILabel()
    let quoteBubble = BubbleBackgroundView()
    let quoteLabel = UILabel()
    let threadLine = CAShapeLayer()
    let bubble = BubbleBackgroundView()
    let textLabel = ConversationEffectLabel()
    let emojiLabel = UILabel()
    let linkCard = ConversationLinkPreviewView()
    let avatar = ConversationAvatarView()
    let reactionBadge = ReactionBadgeView()
    let footerLabel = UILabel()
    let editedLabel = UILabel()
    let repliesLabel = UILabel()
    let translationLabel = UILabel()
    let failedBadge = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    let timeLabel = UILabel()
    let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private(set) var imageViews: [UIImageView] = []
    /// Send-effect state (see MessageCell+Effects).
    let replayButton = UIButton(type: .system)
    var effectStage: MessageBubbleStage?
    var inkView: InvisibleInkView?
    /// Poll card pieces, added on first use (ConversationPolls.swift).
    let pollCard = PollCardView()
    let addChoiceButton = UIButton(type: .system)
    let pollFailedLabel = UILabel()
    /// Everything that moves with the bubble during swipes.
    let shiftable = UIView()
    /// Audio messages (created on first use; see ConversationAudioViews).
    weak var audioDelegate: (any AudioMessageCellDelegate)?
    var audioViews: AudioMessageCellViews?
    private(set) lazy var accessibility = MessageCellAccessibility(cell: self)

    private(set) var model: MessageRowModel?
    private var previousRowID: String?
    private var imageRowID: String?
    private(set) var cellLayout: MessageCellLayout?
    private var imageTasks: [Task<Void, Never>] = []

    /// Swipe-left timestamp reveal, 0...1 of the reveal distance (applied by the controller).
    var timestampReveal: CGFloat = 0 { didSet { applyShifts() } }
    /// Points outgoing content travels at a full reveal (set per swipe).
    var timestampRevealDistance: CGFloat = 58 { didSet { applyShifts() } }
    /// Swipe-right reply drag offset in points.
    var replyDrag: CGFloat = 0 { didSet { applyShifts() } }
    /// Select mode leading shift for incoming rows.
    var selectionShift: CGFloat = 0 { didSet { applyShifts() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(shiftable)
        shiftable.layer.insertSublayer(threadLine, at: 0)
        threadLine.fillColor = nil
        threadLine.lineWidth = 2.5
        threadLine.lineCap = .round
        senderLabel.font = ConversationTheme.senderNameFont
        senderLabel.textColor = ConversationTheme.secondaryText
        quoteLabel.numberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        textLabel.numberOfLines = 0
        emojiLabel.font = .systemFont(ofSize: ConversationTheme.emojiOnlyFontSize)
        emojiLabel.numberOfLines = 0
        footerLabel.font = ConversationTheme.footerFont
        footerLabel.textColor = ConversationTheme.timestampText
        footerLabel.textAlignment = .right
        editedLabel.font = ConversationTheme.editedFont
        editedLabel.textColor = .systemBlue
        repliesLabel.font = ConversationTheme.editedFont
        repliesLabel.textColor = .systemBlue
        failedBadge.tintColor = ConversationTheme.notDelivered
        failedBadge.contentMode = .scaleAspectFit
        timeLabel.font = ConversationTheme.timestampFont
        timeLabel.textColor = ConversationTheme.timestampText
        timeLabel.alpha = 0
        replyArrow.tintColor = ConversationTheme.secondaryText
        replyArrow.contentMode = .center
        replyArrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        replyArrow.alpha = 0
        translationLabel.accessibilityIdentifier = "conversation.message.translation"
        for view in [senderLabel, quoteBubble, quoteLabel, bubble, textLabel, emojiLabel, avatar, reactionBadge, editedLabel, repliesLabel, translationLabel] {
            shiftable.addSubview(view)
        }
        shiftable.insertSubview(linkCard, belowSubview: reactionBadge)
        shiftable.bringSubviewToFront(reactionBadge)
        for view in [footerLabel, failedBadge, timeLabel, replyArrow] {
            contentView.addSubview(view)
        }
        installEffectViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
        previousRowID = nil
        imageRowID = nil
        timestampReveal = 0
        replyDrag = 0
        contentView.alpha = 1
        shiftable.alpha = 1
        shiftable.subviews.forEach { $0.alpha = 1 }
        shiftable.layer.removeAllAnimations()
        shiftable.transform = .identity
        contentView.transform = .identity
        contentView.mask = nil
        resetEffects()
    }

    func configure(model: MessageRowModel, layout: MessageCellLayout, text: NSAttributedString) {
        // A cell showing a different row than before (fresh, reused, or
        // rebound during a page insert) must not animate from the previous
        // row's geometry: inside an animated batch update that drew a stale
        // bubble hundreds of points tall morphing into place.
        guard previousRowID == model.rowID else {
            UIView.performWithoutAnimation {
                configureContents(model: model, layout: layout, text: text)
                layoutIfNeeded()
            }
            for view in [bubble, quoteBubble, textLabel, emojiLabel, avatar, reactionBadge] as [UIView] {
                view.layer.removeAllAnimations()
            }
            return
        }
        configureContents(model: model, layout: layout, text: text)
    }

    private func configureContents(model: MessageRowModel, layout: MessageCellLayout, text: NSAttributedString) {
        let wasScheduled = self.model?.rowID == model.rowID && self.model?.message.isScheduled == true
        self.model = model
        self.cellLayout = layout
        let message = model.message
        placeShiftable()
        applyScaledFonts()

        senderLabel.isHidden = layout.senderNameFrame == nil
        senderLabel.font = ConversationTheme.senderNameFont
        senderLabel.text = model.senderName
        if let frame = layout.senderNameFrame { senderLabel.frame = frame }

        if let quote = model.replyQuote, let quoteFrame = layout.quoteFrame, let quoteTextFrame = layout.quoteTextFrame {
            quoteBubble.isHidden = false
            quoteLabel.isHidden = false
            quoteBubble.side = quote.isOutgoing ? .trailing : .leading
            quoteBubble.hasTail = true
            // Quotes are outline-only, stroked in the original bubble's color.
            quoteBubble.fillColor = .clear
            quoteBubble.strokeColor = quote.isOutgoing ? ConversationTheme.outgoingBubble : ConversationTheme.quoteStroke
            quoteBubble.frame = quoteFrame
            quoteLabel.font = ConversationTheme.quoteFont
            quoteLabel.text = quote.text
            quoteLabel.textColor = quote.isOutgoing ? ConversationTheme.outgoingBubble : ConversationTheme.secondaryText
            quoteLabel.frame = quoteTextFrame
        } else {
            quoteBubble.isHidden = true
            quoteLabel.isHidden = true
        }
        threadLine.path = layout.threadPath
        threadLine.isHidden = layout.threadPath == nil
        threadLine.strokeColor = ConversationTheme.replyThread.resolvedColor(with: traitCollection).cgColor

        configureImages(model: model, layout: layout)
        configurePoll(model: model, layout: layout)

        if let bubbleFrame = layout.bubbleFrame {
            bubble.isHidden = false
            textLabel.isHidden = layout.textFrame == nil
            bubble.side = model.isOutgoing ? .trailing : .leading
            bubble.hasTail = model.showsTail && !layout.linkCardIsLast
            bubble.fillColor = model.isOutgoing
                ? (message.delivery?.isFailed == true ? ConversationTheme.failedBubble : ConversationTheme.outgoingBubble)
                : ConversationTheme.incomingBubble
            bubble.screenGradient = model.isOutgoing ? ConversationTheme.iMessageGradient : nil
            bubble.adaptsToBackdrop = !model.isOutgoing
            bubble.frame = bubbleFrame
            textLabel.effectSeed = ConversationTextEffectMotion.seed(model.rowID)
            textLabel.attributedText = text
            if let textFrame = layout.textFrame { textLabel.frame = textFrame }
            applySendLaterStyle(scheduled: message.isScheduled, wasScheduled: wasScheduled, text: text)
        } else {
            bubble.isHidden = true
            textLabel.isHidden = true
        }

        if let frame = layout.linkCardFrame, let card = layout.linkCard, let preview = message.linkPreview {
            linkCard.isHidden = false
            linkCard.frame = model.showsTail && layout.linkCardIsLast
                ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + ConversationTheme.tailDrop)
                : frame
            linkCard.configure(preview: preview, layout: card, side: model.isOutgoing ? .trailing : .leading, tail: model.showsTail && layout.linkCardIsLast)
        } else {
            linkCard.isHidden = true
        }

        emojiLabel.isHidden = layout.emojiFrame == nil
        if let frame = layout.emojiFrame {
            emojiLabel.font = .systemFont(ofSize: ConversationTheme.emojiOnlyFontSize(count: MessageCellLayout.emojiCount(message.text)))
            emojiLabel.text = message.text
            emojiLabel.textAlignment = model.isOutgoing ? .right : .left
            emojiLabel.frame = MessageCellLayout.emojiGlyphFrame(in: frame)
        }

        avatar.isHidden = layout.avatarFrame == nil
        if let frame = layout.avatarFrame {
            avatar.frame = frame
            avatar.configure(initials: model.senderInitials, colorHex: nil)
        }

        if let anchor = layout.reactionAnchor {
            reactionBadge.isHidden = false
            let kinds = model.reactionKinds
            // Messages: the badge's center sits 3 pt inside the bubble's top
            // corner and 10 pt above it; its dots trail outward, away from the bubble.
            reactionBadge.pointsLeft = model.isOutgoing
            reactionBadge.configure(reactions: kinds, mine: model.hasMyReaction && kinds.count == 1)
            let size = ReactionBadgeView.size(count: kinds.count)
            let x = model.isOutgoing ? anchor.x + 3 - ReactionBadgeView.dotInset - ConversationTheme.reactionBadgeSize / 2 : anchor.x - 3 - size.width + ReactionBadgeView.dotInset + ConversationTheme.reactionBadgeSize / 2
            reactionBadge.frame = CGRect(x: x, y: anchor.y - 10 - ConversationTheme.reactionBadgeSize / 2, width: size.width, height: size.height)
        } else {
            reactionBadge.isHidden = true
        }

        // Status transitions measured on iOS 26 Messages.
        let sameRow = previousRowID == model.rowID
        let footerWasHidden = footerLabel.isHidden
        let previousFooterText = footerLabel.attributedText
        let wasNotDelivered = !footerWasHidden && footerLabel.textColor == ConversationTheme.notDelivered
        defer {
            // Explicit layer animations: these run the same inside a batch
            // update, a spring, or performWithoutAnimation.
            if sameRow, footerWasHidden, !footerLabel.isHidden {
                // A status landing on this row grows out of its own center.
                footerLabel.alpha = 1
                footerLabel.layer.add(Self.statusAnimation(appearing: true), forKey: "statusFade")
            } else if sameRow, !footerWasHidden, footerLabel.isHidden, !wasNotDelivered {
                // (Not Delivered leaves at once on Try Again; the row is moving.)
                // A status leaving this row shrinks slightly and fades in ~0.1 s.
                footerLabel.isHidden = false
                footerLabel.attributedText = previousFooterText
                footerLabel.alpha = 0
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self, self.model?.footer == MessageFooter.none else { return }
                    self.footerLabel.isHidden = true
                }
                footerLabel.layer.add(Self.statusAnimation(appearing: false), forKey: "statusFade")
                CATransaction.commit()
            } else if !footerLabel.isHidden {
                footerLabel.alpha = 1
            }
            previousRowID = model.rowID
        }
        switch model.footer {
        case .none:
            footerLabel.isHidden = true
        case let .status(title, detail):
            footerLabel.isHidden = false
            footerLabel.attributedText = Self.statusText(title: title, detail: detail)
        case .notDelivered:
            footerLabel.isHidden = false
            footerLabel.font = ConversationTheme.footerFont
            footerLabel.text = message.isScheduled
                ? String(localized: "conversation.sendLater.failed", defaultValue: "Your scheduled message will not send.", bundle: .module)
                : String(localized: "conversation.status.notDelivered", defaultValue: "Not Delivered", bundle: .module)
            footerLabel.textColor = ConversationTheme.notDelivered
        }
        if var frame = layout.footerFrame {
            // Hug the text so the status scales about its own center.
            let textWidth = min(frame.width, ceil(footerLabel.intrinsicContentSize.width))
            if model.isOutgoing { frame.origin.x = frame.maxX - textWidth }
            frame.size.width = textWidth
            // Never animate the status label's frame (that reads as a wipe).
            UIView.performWithoutAnimation { footerLabel.setUntransformedFrame(frame) }
            footerLabel.textAlignment = model.isOutgoing ? .right : .left
        }
        let badgeWasHidden = failedBadge.isHidden
        failedBadge.isHidden = layout.failedBadgeFrame == nil
        if let frame = layout.failedBadgeFrame {
            // The badge is born at its place; only the bubble glides over to it.
            UIView.performWithoutAnimation { failedBadge.setUntransformedFrame(frame) }
        }
        if sameRow, badgeWasHidden, !failedBadge.isHidden {
            // A send failing on this row: the red badge pops in.
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.3
            pop.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [pop, fade]
            group.duration = 0.25
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            failedBadge.layer.add(group, forKey: "failedPop")
        }

        editedLabel.isHidden = layout.editedFrame == nil
        if let frame = layout.editedFrame {
            editedLabel.text = String(localized: "conversation.message.edited", defaultValue: "Edited", bundle: .module)
            editedLabel.frame = frame
            editedLabel.textAlignment = model.isOutgoing ? .right : .left
        }
        repliesLabel.isHidden = layout.repliesFrame == nil
        if let frame = layout.repliesFrame {
            repliesLabel.text = message.replyCount == 1
                ? String(localized: "conversation.message.oneReply", defaultValue: "1 Reply", bundle: .module)
                : String(format: String(localized: "conversation.message.replies", defaultValue: "%d Replies", bundle: .module), message.replyCount)
            repliesLabel.frame = frame
            repliesLabel.textAlignment = model.isOutgoing ? .right : .left
        }
        translationLabel.isHidden = layout.translationFrame == nil
        if let frame = layout.translationFrame, let caption = model.translation {
            translationLabel.attributedText = ConversationTranslationText.caption(caption, alignment: model.isOutgoing ? .right : .left)
            translationLabel.frame = frame
        }

        configureAudio(model: model, layout: layout)
        timeLabel.text = message.sentAt.formatted(date: .omitted, time: .shortened)
        setNeedsLayout()
        applyShifts()
        accessibility.update(model: model, layout: layout)
        configureEffects(model: model, layout: layout)
    }

    /// Keeps outgoing bubbles' screen-anchored gradient in step with scrolling.
    func updateScreenGradients() {
        bubble.updateScreenGradient()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeShiftable()
        guard let cellLayout else { return }
        // The time waits just past the trailing edge until a swipe reveals it.
        timeLabel.sizeToFit()
        let anchor = cellLayout.contentFrame
        timeLabel.setUntransformedFrame(CGRect(x: contentView.bounds.width + 8, y: anchor.midY - timeLabel.bounds.height / 2, width: timeLabel.bounds.width, height: timeLabel.bounds.height))
        replyArrow.frame = CGRect(x: 0, y: anchor.midY - 15, width: 30, height: 30)
        applyShifts()
    }

    private func configureImages(model: MessageRowModel, layout: MessageCellLayout) {
        let sameImageRow = imageRowID == model.rowID
        imageRowID = model.rowID
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
        while imageViews.count < layout.imageFrames.count {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = ConversationTheme.bubbleCornerRadius
            view.layer.cornerCurve = .continuous
            view.backgroundColor = UIColor.secondarySystemFill
            shiftable.insertSubview(view, belowSubview: reactionBadge)
            imageViews.append(view)
        }
        for (index, view) in imageViews.enumerated() {
            guard index < layout.imageFrames.count, index < model.message.imageAttachments.count else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            // Images take the bubble outline; the last one in a run gets the
            // tail, which hangs below the full-height photo as in Messages.
            let tailed = model.showsTail && index == layout.imageFrames.count - 1 && model.message.text.isEmpty
            var frame = layout.imageFrames[index]
            if tailed { frame.size.height += ConversationTheme.tailDrop }
            view.frame = frame
            let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            var maskRect = view.bounds
            if tailed { maskRect.size.height -= ConversationTheme.tailDrop }
            mask.path = BubbleShape.path(in: maskRect, side: model.isOutgoing ? .trailing : .leading, tail: tailed).cgPath
            view.layer.mask = mask
            view.layer.cornerRadius = 0
            let attachment = model.message.imageAttachments[index]
            let pixelWidth = view.frame.width * (window?.screen.scale ?? 3)
            if let cached = ConversationImageLoader.shared.cachedImage(for: attachment, pixelWidth: pixelWidth) {
                view.image = cached
                continue
            }
            // Keep what this row already shows (the local copy) while the
            // server copy decodes, so an ack never flashes the placeholder.
            if !sameImageRow { view.image = nil }
            let rowID = model.rowID
            imageTasks.append(Task { @MainActor [weak self, weak view] in
                let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: pixelWidth)
                guard let self, let view, self.model?.rowID == rowID, !Task.isCancelled else { return }
                UIView.transition(with: view, duration: 0.18, options: .transitionCrossDissolve) {
                    view.image = image
                }
            })
        }
    }

    /// Frame of the lifted content in this cell's coordinates.
    /// Hides only what the lifted preview shows (bubble, badge, quote); the
    /// sender name and avatar stay put, so nothing pops in when it lands.
    func setLiftedContentHidden(_ hidden: Bool) {
        let lifted = liftedContentFrame
        for view in shiftable.subviews where view !== avatar && view !== senderLabel {
            if hidden {
                if view.frame.intersects(lifted) { view.alpha = 0 }
            } else {
                view.alpha = 1
            }
        }
    }

    /// The lifted preview includes the tapback badge, which overhangs the
    /// bubble; cutting it at the bubble bounds left a stray fragment.
    var liftedContentFrame: CGRect {
        guard let content = cellLayout?.contentFrame else { return contentView.bounds }
        guard !reactionBadge.isHidden, reactionBadge.frame.width > 0 else { return content }
        return content.union(reactionBadge.frame).intersection(contentView.bounds.insetBy(dx: 0, dy: -20))
    }

    /// Sizes the shiftable container without touching its transform: setting
    /// `frame` on a view whose transform holds the select/reply/timestamp
    /// translation moves its center by that offset, which cancelled the
    /// select shift for reconfigured rows and left them offset after exit.
    private func placeShiftable() {
        shiftable.setUntransformedFrame(contentView.bounds)
    }

    private func applyShifts() {
        guard let model else { return }
        let reveal = timestampReveal * timestampRevealDistance
        var x: CGFloat = 0
        if model.isOutgoing { x -= reveal }
        x += replyDrag + selectionShift
        shiftable.transform = CGAffineTransform(translationX: x, y: 0)
        footerLabel.transform = CGAffineTransform(translationX: model.isOutgoing ? -reveal : 0, y: 0)
        failedBadge.transform = shiftable.transform
        // The time slides in from just past the edge (no fade), a little
        // faster than the bubbles, and ends at the 16 pt margin.
        timeLabel.alpha = timestampReveal > 0 ? 1 : 0
        timeLabel.transform = CGAffineTransform(translationX: -Self.timeTravel(forTimeWidth: timeLabel.bounds.width) * timestampReveal, y: 0)
        let replyProgress = min(1, replyDrag / 60)
        replyArrow.alpha = replyProgress
        let arrowX = model.isOutgoing ? max(0, layoutOrigin(model) - 34) : max(4, replyDrag - 34)
        replyArrow.frame.origin.x = arrowX
        replyArrow.transform = CGAffineTransform(scaleX: 0.5 + 0.5 * replyProgress, y: 0.5 + 0.5 * replyProgress)
    }

    /// Appearing: grows from its center on a critically damped spring
    /// (response 0.52 s) while fading in over 0.25 s; leaving: fades and
    /// shrinks to 0.9 in 0.1 s.
    static func statusAnimation(appearing: Bool) -> CAAnimation {
        let group = CAAnimationGroup()
        if appearing {
            let scale = CASpringAnimation(keyPath: "transform")
            scale.isAdditive = true
            scale.mass = 1
            scale.stiffness = 144
            scale.damping = 24
            scale.fromValue = CATransform3DMakeScale(0.01, 0.01, 1)
            scale.toValue = CATransform3DIdentity
            scale.duration = scale.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.animations = [scale, fade]
            group.duration = scale.duration
        } else {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.isAdditive = true
            scale.fromValue = CATransform3DIdentity
            scale.toValue = CATransform3DMakeScale(0.9, 0.9, 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            group.animations = [scale, fade]
            group.duration = 0.1
        }
        return group
    }

    /// Messages sets "Read" semibold and its time regular, both in the status gray.
    static func statusText(title: String, detail: String?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: ConversationTheme.footerFont,
            .foregroundColor: ConversationTheme.timestampText,
        ])
        if let detail {
            text.append(NSAttributedString(string: " " + detail, attributes: [
                .font: ConversationTheme.footerDetailFont,
                .foregroundColor: ConversationTheme.timestampText,
            ]))
        }
        return text
    }

    /// The time waits 8 pt past the trailing edge and travels to the 16 pt margin.
    static func timeTravel(forTimeWidth width: CGFloat) -> CGFloat { width + 24 }
    /// Bubble travel that clears the widest time by 17 pt (58 pt for "3:16 AM").
    static func timestampRevealDistance(forTimeWidth width: CGFloat) -> CGFloat { (width + 16).rounded() }
    var timeLabelWidth: CGFloat { timeLabel.bounds.width }

    private func layoutOrigin(_ model: MessageRowModel) -> CGFloat {
        (cellLayout?.contentFrame.minX ?? 0) + replyDrag
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        threadLine.strokeColor = ConversationTheme.replyThread.resolvedColor(with: traitCollection).cgColor
    }
}

extension MessageCell {
    /// A scheduled message is an outlined bubble (dashed, tint stroke, no
    /// fill, label-colored text). When it is sent the same cell fills in.
    fileprivate func applySendLaterStyle(scheduled: Bool, wasScheduled: Bool, text: NSAttributedString) {
        bubble.isDashed = scheduled
        guard scheduled else {
            bubble.strokeColor = nil
            if wasScheduled {
                bubble.animateFill(from: .clear, duration: 0.3)
                UIView.transition(with: textLabel, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction], animations: nil)
            }
            return
        }
        bubble.fillColor = .clear
        bubble.strokeColor = SendLaterStyle.outline
        let recolored = NSMutableAttributedString(attributedString: text)
        recolored.addAttribute(.foregroundColor, value: ConversationTheme.incomingText, range: NSRange(location: 0, length: recolored.length))
        textLabel.attributedText = recolored
    }
}

/// Centered "Today 9:41 PM" separator: day bold, time regular.
final class TimestampCell: UICollectionViewCell {
    static let reuseID = "timestamp"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(date: Date) {
        label.attributedText = Self.text(for: date)
        setNeedsLayout()
    }

    /// A system line in the transcript ("**You** unsent a message"): the
    /// timestamp's weights and color; a failure ("(!) Not Unsent") is red.
    func configure(notice: ConversationNotice) {
        let text = NSMutableAttributedString()
        let regular: [NSAttributedString.Key: Any] = [.font: ConversationTheme.timestampFont, .foregroundColor: ConversationTheme.secondaryText]
        text.append(NSAttributedString(string: notice.leading, attributes: regular))
        text.append(NSAttributedString(string: notice.emphasis, attributes: [
            .font: ConversationTheme.timestampBoldFont, .foregroundColor: ConversationTheme.secondaryText,
        ]))
        let parts = notice.trailingParts
        text.append(NSAttributedString(string: parts.before, attributes: regular))
        if let failure = notice.failure {
            let red: [NSAttributedString.Key: Any] = [.font: ConversationTheme.timestampFont, .foregroundColor: ConversationTheme.notDelivered]
            if let range = failure.range(of: "(!)"),
               let symbol = UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(font: ConversationTheme.timestampFont)) {
                text.append(NSAttributedString(string: String(failure[..<range.lowerBound]), attributes: red))
                let attachment = NSTextAttachment(image: symbol.withTintColor(ConversationTheme.notDelivered, renderingMode: .alwaysOriginal))
                text.append(NSAttributedString(attachment: attachment))
                text.append(NSAttributedString(string: String(failure[range.upperBound...]), attributes: red))
            } else {
                text.append(NSAttributedString(string: failure, attributes: red))
            }
        }
        text.append(NSAttributedString(string: parts.after, attributes: regular))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        text.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: text.length))
        label.attributedText = text
        accessibilityLabel = notice.text
        accessibilityTraits = notice.failure == nil ? .staticText : [.staticText, .button]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 16, y: 10, width: contentView.bounds.width - 32, height: max(18, ceil(ConversationTheme.timestampFont.lineHeight)))
    }

    /// Messages sets the next bubble 10.6 pt below the separator's baseline
    /// (28.6 pt at Large); the row grows with the caption 2 timestamp font.
    static var height: CGFloat { 28.6 + max(0, ceil(ConversationTheme.timestampFont.lineHeight) - 14) }

    static func text(for date: Date, now: Date = Date()) -> NSAttributedString {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) {
            day = String(localized: "conversation.timestamp.today", defaultValue: "Today", bundle: .module)
        } else if calendar.isDateInYesterday(date) {
            day = String(localized: "conversation.timestamp.yesterday", defaultValue: "Yesterday", bundle: .module)
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let result = NSMutableAttributedString(string: day, attributes: [
            .font: ConversationTheme.timestampBoldFont,
            .foregroundColor: ConversationTheme.timestampText,
        ])
        result.append(NSAttributedString(string: " " + time, attributes: [
            .font: ConversationTheme.timestampFont,
            .foregroundColor: ConversationTheme.timestampText,
        ]))
        return result
    }
}

/// Spinner shown while an older page is in flight.
final class LoadingCell: UICollectionViewCell {
    static let reuseID = "loading"
    /// ChatKit's load-more row (CKTranscriptHeaderCell.defaultCellHeight).
    static let height: CGFloat = 20
    let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(spinner)
        spinner.hidesWhenStopped = false
        spinner.color = .secondaryLabel
        accessibilityIdentifier = "conversation.loadingOlder"
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "conversation.loadingOlder", defaultValue: "Loading earlier messages", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(active: Bool) {
        spinner.alpha = active ? 1 : 0
        active ? spinner.startAnimating() : spinner.stopAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }
}

/// The top of history: service name and subtitle, as Messages shows above the first message.
final class ConversationStartCell: UICollectionViewCell {
    static let reuseID = "start"
    static var height: CGFloat { max(54, 2 * ceil(ConversationTheme.font(11, style: .caption2).lineHeight) + 26) }
    private let title = UILabel()
    private let subtitle = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = ConversationTheme.secondaryText
        title.textAlignment = .center
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = ConversationTheme.secondaryText
        subtitle.textAlignment = .center
        contentView.addSubview(title)
        contentView.addSubview(subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        self.title.font = ConversationTheme.font(11, .semibold, style: .caption2)
        self.title.text = title
        let attachment = NSTextAttachment(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))!.withTintColor(ConversationTheme.secondaryText, renderingMode: .alwaysOriginal))
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + subtitle, attributes: [.font: ConversationTheme.font(11, style: .caption2), .foregroundColor: ConversationTheme.secondaryText]))
        self.subtitle.attributedText = text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let line = max(14, ceil(title.font.lineHeight))
        title.frame = CGRect(x: 0, y: 14, width: contentView.bounds.width, height: line)
        subtitle.frame = CGRect(x: 0, y: 15 + line, width: contentView.bounds.width, height: line)
    }
}

final class TypingCell: UICollectionViewCell {
    static let reuseID = "typing"
    let indicator = TypingIndicatorView()
    let avatar = ConversationAvatarView()
    var margin: CGFloat = 20 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(indicator)
        contentView.addSubview(avatar)
        isAccessibilityElement = true
        accessibilityIdentifier = "conversation.typing"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.transform = .identity
        contentView.mask = nil
        indicator.transform = .identity
        indicator.alpha = 1
    }

    static func height(isGroup: Bool) -> CGFloat {
        TypingIndicatorView.bubbleSize.height + 12
    }

    func configure(initials: String?, showsAvatar: Bool, accessibilityName: String) {
        avatar.isHidden = !showsAvatar
        avatar.configure(initials: initials ?? "", colorHex: nil)
        accessibilityLabel = String(format: String(localized: "conversation.typing.label", defaultValue: "%@ is typing", bundle: .module), accessibilityName)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let column: CGFloat = avatar.isHidden ? 0 : ConversationTheme.avatarSize + ConversationTheme.avatarGap
        let size = TypingIndicatorView.bubbleSize
        avatar.frame = CGRect(x: margin, y: 2 + size.height - ConversationTheme.avatarSize, width: ConversationTheme.avatarSize, height: ConversationTheme.avatarSize)
        indicator.frame = CGRect(x: margin + column - ConversationTheme.tailWidth, y: 2, width: size.width + ConversationTheme.tailWidth, height: size.height + 10)
    }
}
extension UIView {
    /// Places the view's untransformed box at `frame`, leaving `transform`
    /// applied on top (`frame =` is undefined while a transform is set).
    func setUntransformedFrame(_ frame: CGRect) {
        bounds = CGRect(origin: bounds.origin, size: frame.size)
        center = CGPoint(x: frame.midX, y: frame.midY)
    }
}
#endif
