#if canImport(UIKit)
import CmuxConversationCore
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
    let textLabel = UILabel()
    let emojiLabel = UILabel()
    let avatar = ConversationAvatarView()
    let reactionBadge = ReactionBadgeView()
    let footerLabel = UILabel()
    let editedLabel = UILabel()
    let repliesLabel = UILabel()
    let failedBadge = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    let timeLabel = UILabel()
    let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private(set) var imageViews: [UIImageView] = []
    /// Everything that moves with the bubble during swipes.
    let shiftable = UIView()

    private(set) var model: MessageRowModel?
    private var previousRowID: String?
    private var imageRowID: String?
    private(set) var cellLayout: MessageCellLayout?
    private var imageTasks: [Task<Void, Never>] = []

    /// Swipe-left timestamp reveal, 0...1 of the reveal distance (applied by the controller).
    var timestampReveal: CGFloat = 0 { didSet { applyShifts() } }
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
        quoteLabel.font = .systemFont(ofSize: 15)
        quoteLabel.numberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        textLabel.numberOfLines = 0
        emojiLabel.font = .systemFont(ofSize: ConversationTheme.emojiOnlyFontSize)
        emojiLabel.numberOfLines = 0
        footerLabel.font = ConversationTheme.footerFont
        footerLabel.textColor = ConversationTheme.secondaryText
        footerLabel.textAlignment = .right
        editedLabel.font = ConversationTheme.editedFont
        editedLabel.textColor = .systemBlue
        repliesLabel.font = ConversationTheme.editedFont
        repliesLabel.textColor = .systemBlue
        failedBadge.tintColor = ConversationTheme.notDelivered
        failedBadge.contentMode = .scaleAspectFit
        timeLabel.font = ConversationTheme.timestampFont
        timeLabel.textColor = ConversationTheme.secondaryText
        timeLabel.alpha = 0
        replyArrow.tintColor = ConversationTheme.secondaryText
        replyArrow.contentMode = .center
        replyArrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        replyArrow.alpha = 0
        for view in [senderLabel, quoteBubble, quoteLabel, bubble, textLabel, emojiLabel, avatar, reactionBadge, editedLabel, repliesLabel] {
            shiftable.addSubview(view)
        }
        shiftable.bringSubviewToFront(reactionBadge)
        for view in [footerLabel, failedBadge, timeLabel, replyArrow] {
            contentView.addSubview(view)
        }
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
        self.model = model
        self.cellLayout = layout
        let message = model.message
        placeShiftable()

        senderLabel.isHidden = layout.senderNameFrame == nil
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

        if let bubbleFrame = layout.bubbleFrame, let textFrame = layout.textFrame {
            bubble.isHidden = false
            textLabel.isHidden = false
            bubble.side = model.isOutgoing ? .trailing : .leading
            bubble.hasTail = model.showsTail
            bubble.fillColor = model.isOutgoing
                ? (message.delivery?.isFailed == true ? ConversationTheme.failedBubble : ConversationTheme.outgoingBubble)
                : ConversationTheme.incomingBubble
            bubble.frame = bubbleFrame
            textLabel.attributedText = text
            textLabel.frame = textFrame
        } else {
            bubble.isHidden = true
            textLabel.isHidden = true
        }

        emojiLabel.isHidden = layout.emojiFrame == nil
        if let frame = layout.emojiFrame {
            emojiLabel.text = message.text
            emojiLabel.frame = frame
        }

        avatar.isHidden = layout.avatarFrame == nil
        if let frame = layout.avatarFrame {
            avatar.frame = frame
            avatar.configure(initials: model.senderInitials, colorHex: nil)
        }

        if let anchor = layout.reactionAnchor {
            reactionBadge.isHidden = false
            let kinds = model.reactionKinds
            reactionBadge.pointsLeft = !model.isOutgoing
            reactionBadge.configure(reactions: kinds, mine: model.hasMyReaction && kinds.count == 1)
            let size = ReactionBadgeView.size(count: kinds.count)
            // Overlaps the corner by ~12 pt in each direction.
            let x = model.isOutgoing ? anchor.x - size.width + 12 : anchor.x - 12
            reactionBadge.frame = CGRect(x: x, y: anchor.y - size.height + 14, width: size.width, height: size.height)
        } else {
            reactionBadge.isHidden = true
        }

        // "Delivered" fades in over ~0.4 s when it first lands on this row.
        let sameRow = previousRowID == model.rowID
        let footerWasHidden = footerLabel.isHidden
        let previousFooterText = footerLabel.text
        defer {
            // Explicit layer animations: these run the same inside a batch
            // update, a spring, or performWithoutAnimation.
            if sameRow, footerWasHidden, !footerLabel.isHidden {
                // A status landing on this row fades in over ~0.45 s.
                footerLabel.alpha = 1
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                // Linear: ~90% at 0.4 s, complete at 0.45 s.
                fade.duration = 0.45
                fade.timingFunction = CAMediaTimingFunction(name: .linear)
                footerLabel.layer.add(fade, forKey: "statusFade")
            } else if sameRow, !footerWasHidden, footerLabel.isHidden {
                // A status leaving this row fades out over ~0.3 s instead of vanishing.
                footerLabel.isHidden = false
                footerLabel.text = previousFooterText
                footerLabel.alpha = 0
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self, self.model?.footer == MessageFooter.none else { return }
                    self.footerLabel.isHidden = true
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.3
                footerLabel.layer.add(fade, forKey: "statusFade")
                CATransaction.commit()
            } else if !footerLabel.isHidden {
                footerLabel.alpha = 1
            }
            previousRowID = model.rowID
        }
        switch model.footer {
        case .none:
            footerLabel.isHidden = true
        case let .status(text):
            footerLabel.isHidden = false
            footerLabel.text = text
            footerLabel.textColor = ConversationTheme.secondaryText
        case .notDelivered:
            footerLabel.isHidden = false
            footerLabel.text = String(localized: "conversation.status.notDelivered", defaultValue: "Not Delivered", bundle: .module)
            footerLabel.textColor = ConversationTheme.notDelivered
        }
        if let frame = layout.footerFrame {
            // Never animate the status label's frame (that reads as a wipe).
            UIView.performWithoutAnimation { footerLabel.setUntransformedFrame(frame) }
            footerLabel.textAlignment = model.isOutgoing ? .right : .left
        }
        failedBadge.isHidden = layout.failedBadgeFrame == nil
        if let frame = layout.failedBadgeFrame { failedBadge.setUntransformedFrame(frame) }

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

        timeLabel.text = message.sentAt.formatted(date: .omitted, time: .shortened)
        setNeedsLayout()
        applyShifts()
        accessibilityLabel = [model.senderName, message.text].compactMap { $0 }.joined(separator: ", ")
        // VoiceOver hears what the bubble shows: "Edited" and the current status.
        accessibilityValue = [
            editedLabel.isHidden ? nil : editedLabel.text,
            footerLabel.isHidden ? nil : footerLabel.text,
        ].compactMap { $0 }.joined(separator: ", ")
        isAccessibilityElement = true
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
            guard index < layout.imageFrames.count, index < model.message.attachments.count else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            view.frame = layout.imageFrames[index]
            // Images take the bubble outline; the last one in a run gets the tail.
            let tailed = model.showsTail && index == layout.imageFrames.count - 1 && model.message.text.isEmpty
            let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            var maskRect = view.bounds
            if tailed { maskRect.size.height -= ConversationTheme.tailDrop }
            mask.path = BubbleShape.path(in: maskRect, side: model.isOutgoing ? .trailing : .leading, tail: tailed).cgPath
            view.layer.mask = mask
            view.layer.cornerRadius = 0
            let attachment = model.message.attachments[index]
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
        let revealDistance: CGFloat = 64
        let reveal = timestampReveal * revealDistance
        var x: CGFloat = 0
        if model.isOutgoing { x -= reveal }
        x += replyDrag + selectionShift
        shiftable.transform = CGAffineTransform(translationX: x, y: 0)
        footerLabel.transform = CGAffineTransform(translationX: model.isOutgoing ? -reveal : 0, y: 0)
        failedBadge.transform = shiftable.transform
        timeLabel.alpha = timestampReveal
        // Right-aligned at the layout margin once fully revealed.
        timeLabel.transform = CGAffineTransform(translationX: -(timeLabel.bounds.width + 8 + 16) * min(1, timestampReveal) - max(0, timestampReveal - 1) * revealDistance, y: 0)
        let replyProgress = min(1, replyDrag / 60)
        replyArrow.alpha = replyProgress
        let arrowX = model.isOutgoing ? max(0, layoutOrigin(model) - 34) : max(4, replyDrag - 34)
        replyArrow.frame.origin.x = arrowX
        replyArrow.transform = CGAffineTransform(scaleX: 0.5 + 0.5 * replyProgress, y: 0.5 + 0.5 * replyProgress)
    }

    private func layoutOrigin(_ model: MessageRowModel) -> CGFloat {
        (cellLayout?.contentFrame.minX ?? 0) + replyDrag
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        threadLine.strokeColor = ConversationTheme.replyThread.resolvedColor(with: traitCollection).cgColor
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

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.inset(by: UIEdgeInsets(top: 10, left: 16, bottom: 4, right: 16))
    }

    static let height: CGFloat = 32

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
            .foregroundColor: ConversationTheme.secondaryText,
        ])
        result.append(NSAttributedString(string: " " + time, attributes: [
            .font: ConversationTheme.timestampFont,
            .foregroundColor: ConversationTheme.secondaryText,
        ]))
        return result
    }
}

/// Spinner shown while an older page is in flight.
final class LoadingCell: UICollectionViewCell {
    static let reuseID = "loading"
    static let height: CGFloat = 44
    let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(spinner)
        spinner.hidesWhenStopped = false
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
    static let height: CGFloat = 54
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
        self.title.text = title
        let attachment = NSTextAttachment(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))!.withTintColor(ConversationTheme.secondaryText, renderingMode: .alwaysOriginal))
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " " + subtitle, attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: ConversationTheme.secondaryText]))
        self.subtitle.attributedText = text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 0, y: 14, width: contentView.bounds.width, height: 14)
        subtitle.frame = CGRect(x: 0, y: 29, width: contentView.bounds.width, height: 14)
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
