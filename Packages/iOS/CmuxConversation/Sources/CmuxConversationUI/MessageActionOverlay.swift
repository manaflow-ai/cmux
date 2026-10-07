#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The long-press surface, measured against iOS 26 Messages: the transcript
/// dims slightly (no blur), the pressed bubble scales up in place, the menu
/// scales in under it, then the tapback capsule grows out of a dot at the
/// bubble's top corner and its tapbacks pop in one after another. Also hosts
/// the reaction detail shown when a tapback badge is tapped.
final class MessageActionOverlay: UIView {
    enum Mode {
        case menu
        case reactionDetail
    }

    struct MenuItem {
        var title: String
        var symbol: String
        var isDestructive = false
        var handler: () -> Void
    }

    /// Geometry and timing measured from iOS 26.3 Messages (see the parity notes in the PR).
    enum Metrics {
        static let previewScale: CGFloat = 1.052
        static let screenInset: CGFloat = 16
        static let barHeight: CGFloat = 64
        static let barCell: CGFloat = 49
        static let barPadding: CGFloat = 7.6
        static let barGlyph: CGFloat = 44
        static let barMargin: CGFloat = 11
        static let barGap: CGFloat = 5
        static let menuGap: CGFloat = 18
        static let menuRow: CGFloat = 42
        static let menuWidth: CGFloat = 250
        static let smiley: CGFloat = 44
        static let tailDot: CGFloat = 7
    }

    private let dim = UIView()
    private let snapshot: UIView
    /// Clips a preview taller than the space between bar and menu.
    private let snapshotClip = UIView()
    /// Darkens the preview for the press highlight.
    private let pressShade = UIView()
    private let sourceFrame: CGRect
    private let reactionBar: UIVisualEffectView
    private let reactionScroll = UIScrollView()
    private var reactionButtons: [UIButton] = []
    private let menu: UIVisualEffectView
    private let emojiButton = makeGlassView(cornerRadius: Metrics.smiley / 2)
    private let tailDot = makeGlassView(cornerRadius: Metrics.tailDot / 2)
    private let menuStack = UIStackView()
    private let detailCard: UIVisualEffectView?
    private let isOutgoing: Bool
    private var finalBarFrame: CGRect = .zero
    private var finalPreviewCenter: CGPoint = .zero
    private var isDismissing = false
    /// Bottom of the header; the bar and preview stay below it.
    var topInset: CGFloat = 0
    var onReaction: ((ConversationReaction) -> Void)?
    var onDismiss: (() -> Void)?
    /// Where the pressed bubble is now. The transcript can move under the
    /// overlay (the keyboard leaves as it opens), so the preview returns to the
    /// live position, not the one it lifted from.
    var currentSourceFrame: (() -> CGRect?)?

    init(
        frame: CGRect,
        snapshot: UIView,
        sourceFrame: CGRect,
        isOutgoing: Bool,
        currentReaction: ConversationReaction?,
        items: [MenuItem],
        mode: Mode,
        reactors: [(name: String, initials: String, reaction: ConversationReaction)]
    ) {
        self.snapshot = snapshot
        self.sourceFrame = sourceFrame
        self.isOutgoing = isOutgoing
        reactionBar = makeGlassView(cornerRadius: Metrics.barHeight / 2)
        menu = makeGlassView(cornerRadius: 26)
        detailCard = mode == .reactionDetail ? makeGlassView(cornerRadius: 22) : nil
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.actions"

        // Messages dims the transcript a little and keeps it sharp.
        dim.frame = bounds
        dim.backgroundColor = UIColor {
            $0.userInterfaceStyle == .dark
                ? UIColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 0.15)
                : UIColor.black.withAlphaComponent(0.06)
        }
        dim.alpha = 0
        addSubview(dim)
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        backgroundTap.cancelsTouchesInView = false
        addGestureRecognizer(backgroundTap)

        snapshotClip.clipsToBounds = true
        snapshotClip.layer.cornerCurve = .continuous
        snapshotClip.frame = sourceFrame
        snapshot.frame = CGRect(origin: .zero, size: sourceFrame.size)
        snapshotClip.addSubview(snapshot)
        pressShade.backgroundColor = .black
        pressShade.alpha = 0
        pressShade.isUserInteractionEnabled = false
        addSubview(snapshotClip)

        // Tapback capsule: the six tapbacks plus recent emoji, scrollable.
        addSubview(reactionBar)
        reactionBar.contentView.addSubview(reactionScroll)
        reactionScroll.showsHorizontalScrollIndicator = false
        reactionScroll.clipsToBounds = false
        for reaction in ConversationReaction.allCases {
            let button = UIButton(type: .custom)
            let glyph = TapbackGlyph.view(for: reaction, size: Metrics.barGlyph)
            glyph.isUserInteractionEnabled = false
            button.addSubview(glyph)
            glyph.frame = CGRect(x: 0, y: 0, width: Metrics.barGlyph, height: Metrics.barGlyph)
            button.layer.cornerRadius = Metrics.barGlyph / 2
            if reaction == currentReaction {
                button.backgroundColor = .systemBlue
            }
            button.accessibilityLabel = reaction.rawValue
            button.accessibilityIdentifier = "conversation.tapback.\(reaction.rawValue)"
            button.addAction(UIAction { [weak self, weak button] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                // The pick turns blue at once, then the capsule folds away.
                button?.backgroundColor = .systemBlue
                self?.onReaction?(reaction)
            }, for: .touchUpInside)
            reactionScroll.addSubview(button)
            reactionButtons.append(button)
        }
        for emoji in ["\u{1F602}", "\u{2764}\u{FE0F}", "\u{1F525}"] {
            let button = UIButton(type: .custom)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 30)
            button.isAccessibilityElement = false
            reactionScroll.addSubview(button)
            reactionButtons.append(button)
        }

        // The custom-emoji circle hangs beside the bubble's top corner with a
        // dot trailing toward it, like a thought bubble.
        addSubview(tailDot)
        addSubview(emojiButton)
        let face = UIImageView(image: UIImage(systemName: "face.smiling", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)))
        face.tintColor = .secondaryLabel
        face.contentMode = .center
        face.frame = CGRect(x: 0, y: 0, width: Metrics.smiley, height: Metrics.smiley)
        emojiButton.contentView.addSubview(face)

        if let detailCard {
            addSubview(detailCard)
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 10
            for reactor in reactors {
                let row = UIStackView()
                row.spacing = 10
                row.alignment = .center
                let avatar = ConversationAvatarView()
                avatar.configure(initials: reactor.initials, colorHex: nil)
                avatar.widthAnchor.constraint(equalToConstant: 30).isActive = true
                avatar.heightAnchor.constraint(equalToConstant: 30).isActive = true
                let name = UILabel()
                name.text = reactor.name
                name.font = .systemFont(ofSize: 15, weight: .medium)
                let glyph = TapbackGlyph.view(for: reactor.reaction, size: 30)
                glyph.widthAnchor.constraint(equalToConstant: 30).isActive = true
                row.addArrangedSubview(avatar)
                row.addArrangedSubview(name)
                row.addArrangedSubview(UIView())
                row.addArrangedSubview(glyph)
                stack.addArrangedSubview(row)
            }
            stack.frame = CGRect(x: 14, y: 12, width: 240, height: CGFloat(reactors.count) * 40 - 10)
            detailCard.contentView.addSubview(stack)
            detailCard.bounds = CGRect(x: 0, y: 0, width: 268, height: CGFloat(reactors.count) * 40 + 14)
        }

        menuStack.axis = .vertical
        addSubview(menu)
        menu.contentView.addSubview(menuStack)
        for (index, item) in items.enumerated() {
            if index == 1, items.count > 3 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                let wrapper = UIView()
                wrapper.addSubview(separator)
                separator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
                    separator.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -24),
                    separator.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                    wrapper.heightAnchor.constraint(equalToConstant: 14),
                ])
                menuStack.addArrangedSubview(wrapper)
            }
            menuStack.addArrangedSubview(MenuRow(item: item) { [weak self] in
                self?.dismiss { item.handler() }
            })
        }
        menu.isHidden = mode == .reactionDetail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var menuSize: CGSize {
        let height = menuStack.arrangedSubviews.reduce(CGFloat(0)) { $0 + ($1 is MenuRow ? Metrics.menuRow : 14) } + 16
        return CGSize(width: Metrics.menuWidth, height: height)
    }

    private var barContentWidth: CGFloat {
        CGFloat(reactionButtons.count) * Metrics.barCell + Metrics.barPadding * 2
    }

    /// The scaled preview's frame for a resting (unscaled) frame, clamped to
    /// the screen inset the way Messages keeps a lifted bubble on screen.
    private func liftedFrame(for rest: CGRect) -> (center: CGPoint, frame: CGRect) {
        let size = CGSize(width: rest.width * Metrics.previewScale, height: rest.height * Metrics.previewScale)
        let lo = Metrics.screenInset + size.width / 2
        let hi = bounds.width - Metrics.screenInset - size.width / 2
        let x = lo <= hi ? min(max(rest.midX, lo), hi) : rest.midX
        let center = CGPoint(x: x, y: rest.midY)
        return (center, CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }

    /// Lays out the final state (preview left at its resting frame; `present`
    /// applies the lift).
    private func layoutFinal() {
        let safe = safeAreaInsets
        let menuSize = menuSize
        let lift = (Metrics.previewScale - 1) / 2
        var rest = sourceFrame
        let topLimit = max(safe.top, topInset) + 8 + Metrics.barHeight + Metrics.barGap + (detailCard.map { $0.bounds.height + 10 } ?? 0)
        let bottomLimit = bounds.height - safe.bottom - 8 - (menu.isHidden ? 0 : menuSize.height + Metrics.menuGap)
        // Keep the bubble in place when possible; shift only as far as needed.
        if rest.maxY + rest.height * lift > bottomLimit { rest.origin.y = bottomLimit - rest.height * (1 + lift) }
        if rest.minY - rest.height * lift < topLimit { rest.origin.y = topLimit + rest.height * lift }
        if rest.height * Metrics.previewScale > bottomLimit - topLimit {
            // Too tall to fit between bar and menu: show its top part, clipped.
            rest.size.height = max(60, (bottomLimit - topLimit) / Metrics.previewScale)
            rest.origin.y = topLimit + rest.height * lift
            snapshotClip.layer.cornerRadius = ConversationTheme.bubbleCornerRadius
        }
        snapshotClip.bounds = CGRect(origin: .zero, size: rest.size)
        let lifted = liftedFrame(for: rest)
        finalPreviewCenter = lifted.center
        let preview = lifted.frame

        // The capsule ends at the bubble's outer edge and runs toward the
        // screen's far side, capped by the margin (its content scrolls).
        let width = min(barContentWidth, bounds.width - Metrics.barMargin * 2)
        let barX = isOutgoing
            ? max(Metrics.barMargin, preview.maxX - width)
            : min(bounds.width - Metrics.barMargin - width, preview.minX)
        finalBarFrame = CGRect(x: barX, y: preview.minY - Metrics.barGap - Metrics.barHeight, width: width, height: Metrics.barHeight)
        reactionBar.frame = finalBarFrame
        reactionScroll.frame = reactionBar.bounds
        for (index, button) in reactionButtons.enumerated() {
            button.frame = CGRect(
                x: Metrics.barPadding + CGFloat(index) * Metrics.barCell + (Metrics.barCell - Metrics.barGlyph) / 2,
                y: (Metrics.barHeight - Metrics.barGlyph) / 2,
                width: Metrics.barGlyph,
                height: Metrics.barGlyph
            )
        }
        reactionScroll.contentSize = CGSize(width: barContentWidth, height: Metrics.barHeight)
        if isOutgoing {
            // Show the tapbacks first, like Messages.
            reactionScroll.contentOffset = .zero
        }

        let side: CGFloat = isOutgoing ? -1 : 1
        let edge = isOutgoing ? preview.minX : preview.maxX
        let smileyCenter = CGPoint(x: edge + side * 28, y: preview.minY + 8)
        emojiButton.frame = CGRect(x: smileyCenter.x - Metrics.smiley / 2, y: smileyCenter.y - Metrics.smiley / 2, width: Metrics.smiley, height: Metrics.smiley)
        let dotCenter = CGPoint(x: smileyCenter.x + side * 21, y: smileyCenter.y + 33)
        tailDot.frame = CGRect(x: dotCenter.x - Metrics.tailDot / 2, y: dotCenter.y - Metrics.tailDot / 2, width: Metrics.tailDot, height: Metrics.tailDot)

        if let detailCard {
            detailCard.frame = CGRect(
                x: isOutgoing ? bounds.width - Metrics.screenInset - detailCard.bounds.width : Metrics.screenInset,
                y: finalBarFrame.minY - detailCard.bounds.height - 10,
                width: detailCard.bounds.width,
                height: detailCard.bounds.height
            )
        }
        let menuY = min(preview.maxY + Metrics.menuGap, bounds.height - safe.bottom - menuSize.height - 8)
        let menuX = isOutgoing ? preview.maxX - menuSize.width : preview.minX
        menu.frame = CGRect(x: min(max(Metrics.screenInset, menuX), bounds.width - Metrics.screenInset - menuSize.width), y: menuY, width: menuSize.width, height: menuSize.height)
        menuStack.frame = menu.bounds.insetBy(dx: 0, dy: 8)
    }

    /// The dot the capsule grows out of (and folds back into): just outside
    /// the bubble's top corner on the side the capsule runs toward.
    private func barSeed(diameter: CGFloat, centerY: CGFloat) -> CGRect {
        let preview = liftedFrame(for: CGRect(center: finalPreviewCenter, size: snapshotClip.bounds.size)).frame
        let x = isOutgoing ? preview.minX + 9 : preview.maxX - 9
        return CGRect(x: x - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
    }

    /// Moves the capsule while its tapbacks stay put on screen, so the capsule
    /// reveals them as it grows instead of dragging them along.
    private func setBarFrame(_ frame: CGRect) {
        reactionBar.frame = frame
        reactionBar.layer.cornerRadius = min(frame.width, frame.height) / 2
        reactionScroll.frame = CGRect(
            x: finalBarFrame.minX - frame.minX,
            y: finalBarFrame.minY - frame.minY,
            width: finalBarFrame.width,
            height: finalBarFrame.height
        )
    }

    func present() {
        layoutFinal()
        let previewTop = finalPreviewCenter.y - snapshotClip.bounds.height * Metrics.previewScale / 2
        snapshotClip.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.minY + snapshotClip.bounds.height / 2)
        snapshotClip.addSubview(pressShade)
        pressShade.frame = snapshotClip.bounds

        // Dim: a light veil, no blur.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.dim.alpha = 1 }

        // Press highlight, then the lift: ~1.05x in place, no overshoot.
        UIView.animateKeyframes(withDuration: 0.17, delay: 0, options: [.allowUserInteraction]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) { self.pressShade.alpha = 0.31 }
            UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) { self.pressShade.alpha = 0 }
        }
        UIView.animate(springDuration: 0.24, bounce: 0, options: [.allowUserInteraction]) {
            self.snapshotClip.center = self.finalPreviewCenter
            self.snapshotClip.transform = CGAffineTransform(scaleX: Metrics.previewScale, y: Metrics.previewScale)
        }

        // Menu: scales in from its top corner right under the bubble.
        if !menu.isHidden {
            let anchor = CGPoint(x: isOutgoing ? 1 : 0, y: 0)
            let frame = menu.frame
            menu.layer.anchorPoint = anchor
            menu.frame = frame
            menu.alpha = 0
            menu.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(withDuration: 0.1, delay: 0.02, options: [.curveEaseOut, .allowUserInteraction]) { self.menu.alpha = 1 }
            UIView.animate(springDuration: 0.2, bounce: 0, initialSpringVelocity: 0, delay: 0.02, options: [.allowUserInteraction]) {
                self.menu.transform = .identity
            }
        }

        // Capsule: a dot at the bubble's corner swells into a circle, then
        // stretches into the capsule; the tapbacks pop in left to right.
        let final = finalBarFrame
        setBarFrame(barSeed(diameter: 10, centerY: previewTop - 8))
        reactionBar.alpha = 0
        UIView.animate(withDuration: 0.05, delay: 0.08, options: [.allowUserInteraction]) { self.reactionBar.alpha = 1 }
        UIView.animate(withDuration: 0.1, delay: 0.08, options: [.curveEaseOut, .allowUserInteraction]) {
            self.setBarFrame(self.barSeed(diameter: 42, centerY: final.midY + 4))
        } completion: { _ in
            guard !self.isDismissing else { return }
            UIView.animate(springDuration: 0.34, bounce: 0, options: [.allowUserInteraction]) {
                self.setBarFrame(final)
            }
        }
        for (index, button) in reactionButtons.enumerated() {
            button.alpha = 0
            button.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            UIView.animate(springDuration: 0.32, bounce: 0.3, initialSpringVelocity: 0, delay: 0.22 + Double(index) * 0.035, options: [.allowUserInteraction]) {
                button.alpha = 1
                button.transform = .identity
            }
        }
        for (view, delay) in [(tailDot, 0.26), (emojiButton, 0.3)] as [(UIView, Double)] {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            UIView.animate(springDuration: 0.3, bounce: 0.25, initialSpringVelocity: 0, delay: delay, options: [.allowUserInteraction]) {
                view.alpha = 1
                view.transform = .identity
            }
        }

        if let detailCard {
            detailCard.alpha = 0
            detailCard.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(springDuration: 0.3, bounce: 0.15, options: [.allowUserInteraction]) {
                detailCard.alpha = 1
                detailCard.transform = .identity
            }
        }
    }

    /// Reverses the presentation: the menu fades, the capsule folds back into
    /// a dot at the bubble's corner, and the preview settles where its row is
    /// now. Measured: capsule gone ~0.33 s after the tap.
    func dismiss(then completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        isUserInteractionEnabled = false
        let home = currentSourceFrame?() ?? sourceFrame
        let corner = CGPoint(x: isOutgoing ? home.minX + 9 : home.maxX - 9, y: home.minY - 8)
        func seed(_ diameter: CGFloat, centerY: CGFloat) -> CGRect {
            CGRect(x: corner.x - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
        }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.menu.alpha = 0
            self.menu.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            self.detailCard?.alpha = 0
            for view in [self.emojiButton, self.tailDot] as [UIView] {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            }
        }
        UIView.animate(withDuration: 0.12, delay: 0.03, options: [.curveEaseIn, .beginFromCurrentState]) {
            for button in self.reactionButtons {
                button.alpha = 0
                button.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }
        }
        UIView.animate(withDuration: 0.18, delay: 0.03, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.setBarFrame(seed(40, centerY: self.finalBarFrame.midY + 6))
        } completion: { _ in
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                self.setBarFrame(seed(4, centerY: corner.y))
                self.reactionBar.alpha = 0
            }
        }
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.curveEaseOut, .beginFromCurrentState]) { self.dim.alpha = 0 }
        // A critically damped spring with a fixed duration, so the follow-up
        // (the tapback landing) starts on Messages' beat.
        UIView.animate(withDuration: 0.3, delay: 0.03, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.snapshotClip.transform = .identity
            self.snapshotClip.center = CGPoint(x: home.midX, y: home.minY + self.snapshotClip.bounds.height / 2)
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismiss?()
            completion?()
        }
    }

    @objc private func backgroundTapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        guard !reactionBar.frame.contains(point), !menu.frame.contains(point), !emojiButton.frame.contains(point) else { return }
        dismiss()
    }

    private final class MenuRow: UIControl {
        private let icon = UIImageView()
        private let label = UILabel()
        private let action: () -> Void

        init(item: MenuItem, action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
            icon.image = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            icon.tintColor = item.isDestructive ? .systemRed : .label
            icon.contentMode = .center
            label.text = item.title
            label.font = .systemFont(ofSize: 17)
            label.textColor = item.isDestructive ? .systemRed : .label
            addSubview(icon)
            addSubview(label)
            heightAnchor.constraint(equalToConstant: Metrics.menuRow).isActive = true
            accessibilityLabel = item.title
            accessibilityTraits = .button
            isAccessibilityElement = true
            accessibilityIdentifier = "conversation.menu.\(item.symbol)"
            addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            icon.frame = CGRect(x: 20, y: 0, width: 28, height: bounds.height)
            label.frame = CGRect(x: 60, y: 0, width: bounds.width - 76, height: bounds.height)
        }

        override var isHighlighted: Bool {
            didSet { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.08) : .clear }
        }
    }
}

private extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

extension ConversationViewController {
    func presentActions(for model: MessageRowModel, cell: MessageCell, mode: MessageActionOverlay.Mode) {
        let contentFrame = cell.liftedContentFrame
        guard let snapshot = cell.shiftable.resizableSnapshotView(from: contentFrame, afterScreenUpdates: false, withCapInsets: .zero) else { return }
        let source = cell.convert(contentFrame, to: view)
        let message = model.message
        let mine = message.reactions.first { $0.participantID == store.meID }?.reaction
        var items: [MessageActionOverlay.MenuItem] = [
            .init(title: String(localized: "conversation.menu.reply", defaultValue: "Reply", bundle: .module), symbol: "arrowshape.turn.up.left") { [weak self] in
                self?.enterReplyMode(for: message)
            },
            .init(title: String(localized: "conversation.menu.copy", defaultValue: "Copy", bundle: .module), symbol: "doc.on.doc") {
                UIPasteboard.general.string = message.text
            },
            .init(title: String(localized: "conversation.menu.select", defaultValue: "Select", bundle: .module), symbol: "checkmark.circle") { [weak self] in
                self?.setSelecting(true, initial: model.rowID)
            },
        ]
        if store.canEdit(message) {
            items.insert(.init(title: String(localized: "conversation.menu.edit", defaultValue: "Edit", bundle: .module), symbol: "pencil") { [weak self] in
                self?.enterEditMode(for: message)
            }, at: 1)
        }
        if model.message.delivery?.isFailed == true {
            items.insert(.init(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), symbol: "arrow.clockwise") { [weak self] in
                self?.store.retry(rowID: model.rowID)
            }, at: 1)
        }
        items.append(.init(title: String(localized: "conversation.menu.more", defaultValue: "More…", bundle: .module), symbol: "ellipsis.circle") { [weak self] in
            self?.setSelecting(true, initial: model.rowID)
        })
        let reactors = message.reactions.compactMap { mark -> (name: String, initials: String, reaction: ConversationReaction)? in
            guard let participant = store.info?.participant(mark.participantID) else { return nil }
            return (participant.isMe ? String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module) : participant.name, participant.initials, mark.reaction)
        }
        // Like the keyboard, the Photos drawer gives way to the menu (Messages
        // closes it); otherwise it would cover the menu's lower rows.
        view.endEditing(true)
        dismissPhotoDrawer()
        let overlay = MessageActionOverlay(
            frame: view.bounds,
            snapshot: snapshot,
            sourceFrame: source,
            isOutgoing: model.isOutgoing,
            currentReaction: mine,
            items: items,
            mode: mode,
            reactors: reactors
        )
        cell.setLiftedContentHidden(true)
        let rowID = model.rowID
        overlay.currentSourceFrame = { [weak self] in
            guard let self, let indexPath = self.indexPath(for: rowID),
                  let live = self.collectionView.cellForItem(at: indexPath) as? MessageCell else { return nil }
            self.collectionView.layoutIfNeeded()
            return live.convert(live.liftedContentFrame, to: self.view)
        }
        overlay.onDismiss = { [weak self, weak cell] in
            cell?.setLiftedContentHidden(false)
            // The row may have been re-dequeued while the overlay was up.
            if let self, let indexPath = self.indexPath(for: rowID) {
                (self.collectionView.cellForItem(at: indexPath) as? MessageCell)?.setLiftedContentHidden(false)
            }
        }
        overlay.onReaction = { [weak self, weak overlay] reaction in
            overlay?.dismiss {
                let next = mine == reaction ? nil : reaction
                self?.store.react(messageID: message.id, reaction: next)
                if next != nil { self?.landReactionBadge(rowID: rowID) }
            }
        }
        overlay.topInset = header.frame.maxY
        view.insertSubview(overlay, belowSubview: header)
        overlay.layoutIfNeeded()
        overlay.present()
    }

    /// Messages lands a new tapback as a tiny bubble at the corner that
    /// swells to full size (slight overshoot) while its row makes room.
    func landReactionBadge(rowID: String) {
        guard let indexPath = indexPath(for: rowID),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              !cell.reactionBadge.isHidden else { return }
        let badge = cell.reactionBadge
        let bounds = badge.bounds
        // Grow out of the corner the badge's dots point to.
        let pivot = CGPoint(x: badge.pointsLeft ? 0 : bounds.width, y: bounds.height)
        let scale: CGFloat = 0.1
        badge.transform = CGAffineTransform(translationX: (pivot.x - bounds.midX) * (1 - scale), y: (pivot.y - bounds.midY) * (1 - scale))
            .scaledBy(x: scale, y: scale)
        badge.alpha = 0
        UIView.animate(withDuration: 0.08, delay: 0.06) { badge.alpha = 1 }
        UIView.animate(springDuration: 0.32, bounce: 0.25, initialSpringVelocity: 0, delay: 0.06, options: [.allowUserInteraction]) {
            badge.transform = .identity
        }
    }
}
#endif
