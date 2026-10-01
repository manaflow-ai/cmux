#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The long-press surface: the transcript blurs and dims, the pressed bubble
/// stays sharp in place, a glass tapback bar sits above it and a glass menu
/// below (or above when there is no room). Also hosts the reaction detail
/// shown when a tapback badge is tapped.
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

    private let blur = UIVisualEffectView(effect: nil)
    private let dim = UIView()
    private let snapshot: UIView
    private let sourceFrame: CGRect
    private let reactionBar: UIVisualEffectView
    private let reactionScroll = UIScrollView()
    private var reactionButtons: [UIButton] = []
    private let menu: UIVisualEffectView
    private let menuStack = UIStackView()
    private let detailCard: UIVisualEffectView?
    private let isOutgoing: Bool
    var onReaction: ((ConversationReaction) -> Void)?
    var onDismiss: (() -> Void)?

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
        reactionBar = makeGlassView(cornerRadius: 26)
        menu = makeGlassView(cornerRadius: 26)
        detailCard = mode == .reactionDetail ? makeGlassView(cornerRadius: 22) : nil
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.actions"

        blur.frame = bounds
        dim.frame = bounds
        dim.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.35) : UIColor.black.withAlphaComponent(0.08) }
        dim.alpha = 0
        addSubview(blur)
        addSubview(dim)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))

        snapshot.frame = sourceFrame
        addSubview(snapshot)

        // Tapback bar: the six tapbacks plus an emoji button, scrollable.
        addSubview(reactionBar)
        reactionBar.contentView.addSubview(reactionScroll)
        reactionScroll.showsHorizontalScrollIndicator = false
        for reaction in ConversationReaction.allCases {
            let button = UIButton(type: .custom)
            let glyph = TapbackGlyph.view(for: reaction, size: 44)
            glyph.isUserInteractionEnabled = false
            button.addSubview(glyph)
            glyph.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            button.layer.cornerRadius = 20
            if reaction == currentReaction {
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.9)
            }
            button.accessibilityLabel = reaction.rawValue
            button.accessibilityIdentifier = "conversation.tapback.\(reaction.rawValue)"
            button.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onReaction?(reaction)
            }, for: .touchUpInside)
            reactionScroll.addSubview(button)
            reactionButtons.append(button)
        }
        for emoji in ["\u{1F602}", "\u{2764}\u{FE0F}", "\u{1F525}"] {
            let button = UIButton(type: .custom)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 26)
            button.isAccessibilityElement = false
            reactionScroll.addSubview(button)
            reactionButtons.append(button)
        }

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
        let height = menuStack.arrangedSubviews.reduce(CGFloat(0)) { $0 + ($1 is MenuRow ? 48 : 14) } + 16
        return CGSize(width: 250, height: height)
    }

    /// Lays out the final state; returns the frame the snapshot settles at.
    private func layoutFinal() -> CGRect {
        let safe = safeAreaInsets
        let barHeight: CGFloat = 52
        let barWidth = min(bounds.width - 32, CGFloat(reactionButtons.count) * 46 + 12)
        let menuSize = menuSize
        var target = sourceFrame
        let topLimit = safe.top + 8 + barHeight + 10 + (detailCard?.bounds.height ?? 0)
        let bottomLimit = bounds.height - safe.bottom - 12 - (menu.isHidden ? 0 : menuSize.height + 10)
        // Keep the bubble in place when possible; shift only as far as needed.
        if target.maxY > bottomLimit { target.origin.y = bottomLimit - target.height }
        if target.minY < topLimit { target.origin.y = topLimit }
        if target.maxY > bounds.height - safe.bottom - 12 {
            // Too tall: keep its top, let it clip under the menu.
            target.origin.y = topLimit
        }
        let barX = isOutgoing ? bounds.width - 16 - barWidth : 16
        reactionBar.frame = CGRect(x: barX, y: target.minY - barHeight - 10, width: barWidth, height: barHeight)
        reactionScroll.frame = reactionBar.bounds
        for (index, button) in reactionButtons.enumerated() {
            button.frame = CGRect(x: 6 + CGFloat(index) * 46, y: 4, width: 44, height: 44)
        }
        reactionScroll.contentSize = CGSize(width: CGFloat(reactionButtons.count) * 46 + 12, height: barHeight)
        if let detailCard {
            detailCard.frame = CGRect(
                x: isOutgoing ? bounds.width - 16 - detailCard.bounds.width : 16,
                y: reactionBar.frame.minY - detailCard.bounds.height - 10,
                width: detailCard.bounds.width,
                height: detailCard.bounds.height
            )
        }
        let menuY = min(target.maxY + 10, bounds.height - safe.bottom - menuSize.height - 8)
        let menuX = isOutgoing ? bounds.width - 16 - menuSize.width : max(16, sourceFrame.minX)
        menu.frame = CGRect(x: menuX, y: menuY, width: menuSize.width, height: menuSize.height)
        menuStack.frame = menu.bounds.insetBy(dx: 0, dy: 8)
        return target
    }

    func present() {
        let target = layoutFinal()
        for view in [reactionBar, menu] + (detailCard.map { [$0] } ?? []) {
            // Grow out of the bubble's side and edge.
            let dx = (isOutgoing ? 1 : -1) * view.bounds.width * 0.2
            let dy = (view === menu ? -1 : 1) * view.bounds.height * 0.2
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: 0.6, y: 0.6)
        }
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        // Main motion ~0.23 s, settled by ~0.5 s.
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.blur.effect = blurEffect
            self.dim.alpha = 1
            self.snapshot.frame = target
            self.snapshot.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
            for view in [self.reactionBar, self.menu] + (self.detailCard.map { [$0] } ?? []) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    func dismiss(then completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            self.blur.effect = nil
            self.dim.alpha = 0
            self.snapshot.frame = self.sourceFrame
            self.snapshot.transform = .identity
            for view in [self.reactionBar, self.menu] + (self.detailCard.map { [$0] } ?? []) {
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismiss?()
            completion?()
        }
    }

    @objc private func backgroundTapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        guard !reactionBar.frame.contains(point), !menu.frame.contains(point) else { return }
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
            heightAnchor.constraint(equalToConstant: 48).isActive = true
            accessibilityLabel = item.title
            accessibilityTraits = .button
            isAccessibilityElement = true
            accessibilityIdentifier = "conversation.menu.\(item.symbol)"
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

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            if let touch, bounds.contains(touch.location(in: self)) { action() }
        }
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
        view.endEditing(true)
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
        cell.shiftable.alpha = 0
        overlay.onDismiss = { [weak cell] in cell?.shiftable.alpha = 1 }
        overlay.onReaction = { [weak self, weak overlay] reaction in
            overlay?.dismiss {
                self?.store.react(messageID: message.id, reaction: mine == reaction ? nil : reaction)
            }
        }
        view.addSubview(overlay)
        overlay.layoutIfNeeded()
        overlay.present()
    }
}
#endif
