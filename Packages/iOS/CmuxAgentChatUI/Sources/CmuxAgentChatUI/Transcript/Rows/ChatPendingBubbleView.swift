import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native optimistic outbound bubble with delivery and recovery controls.
@MainActor
public final class ChatPendingBubbleView: UIView {
    private let pending: ChatPendingOutbound
    private let actions: ChatRowActions

    public init(pending: ChatPendingOutbound, actions: ChatRowActions) {
        self.pending = pending
        self.actions = actions
        super.init(frame: .zero)

        let bubble = makeBubble()
        bubble.alpha = bubbleOpacity
        let column = UIStackView(arrangedSubviews: [bubble, makeDeliveryLine()])
        column.axis = .vertical
        column.alignment = .trailing
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 64),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
        ])
        accessibilityIdentifier = "ChatPendingBubble-\(pending.id)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeBubble() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 6

        if !pending.attachments.isEmpty {
            stack.addArrangedSubview(makeAttachmentGrid())
        }
        if !pending.text.isEmpty {
            let label = UILabel()
            label.text = pending.text
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .white
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }

        let compact = pending.text.isEmpty && !pending.attachments.isEmpty
        let container = UIView()
        container.backgroundColor = .systemBlue
        container.layer.cornerRadius = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: compact ? 6 : 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: compact ? -6 : -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: compact ? 6 : 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: compact ? -6 : -8),
        ])
        return container
    }

    private func makeAttachmentGrid() -> UIView {
        let rows = UIStackView()
        rows.axis = .vertical
        rows.alignment = .trailing
        rows.spacing = 4
        for start in stride(from: 0, to: pending.attachments.count, by: 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            for attachment in pending.attachments[start..<min(start + 2, pending.attachments.count)] {
                row.addArrangedSubview(makeThumbnail(data: attachment.data))
            }
            rows.addArrangedSubview(row)
        }
        rows.isAccessibilityElement = true
        rows.accessibilityLabel = String(
            localized: "chat.pending.attachments.accessibility",
            defaultValue: "\(pending.attachmentCount) attachments",
            bundle: .module
        )
        return rows
    }

    private func makeThumbnail(data: Data) -> UIView {
        let imageView = UIImageView(image: UIImage(data: data) ?? UIImage(systemName: "photo"))
        imageView.contentMode = UIImage(data: data) == nil ? .center : .scaleAspectFill
        imageView.tintColor = UIColor.white.withAlphaComponent(0.8)
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        imageView.layer.cornerRadius = 10
        imageView.layer.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 96),
            imageView.heightAnchor.constraint(equalToConstant: 96),
        ])
        return imageView
    }

    private func makeDeliveryLine() -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        switch pending.delivery {
        case .queued:
            stack.addArrangedSubview(glyph(
                "clock",
                color: .tertiaryLabel,
                label: String(
                    localized: "chat.pending.queued.accessibility",
                    defaultValue: "Queued until the agent is free",
                    bundle: .module
                )
            ))
            stack.addArrangedSubview(actionButton(
                title: String(localized: "chat.pending.cancel", defaultValue: "Cancel", bundle: .module),
                color: .secondaryLabel,
                accessibilityIdentifier: "ChatPendingCancel",
                action: { [actions, id = pending.id] in actions.discardPending(id) }
            ))
        case .sending:
            stack.addArrangedSubview(ChatPendingPulseGlyph())
        case .delivered:
            stack.addArrangedSubview(glyph(
                "checkmark",
                color: .tertiaryLabel,
                label: String(
                    localized: "chat.pending.delivered.accessibility",
                    defaultValue: "Delivered",
                    bundle: .module
                )
            ))
        case .failed:
            stack.addArrangedSubview(glyph(
                "exclamationmark.circle.fill",
                color: .systemRed,
                label: String(
                    localized: "chat.pending.failed.accessibility",
                    defaultValue: "Failed to send",
                    bundle: .module
                )
            ))
            stack.addArrangedSubview(actionButton(
                title: String(localized: "chat.pending.retry", defaultValue: "Retry", bundle: .module),
                color: .systemBlue,
                weight: .semibold,
                accessibilityIdentifier: "ChatPendingRetry",
                action: { [actions, id = pending.id] in actions.retryPending(id) }
            ))
            stack.addArrangedSubview(actionButton(
                title: String(localized: "chat.pending.discard", defaultValue: "Discard", bundle: .module),
                color: .secondaryLabel,
                weight: .semibold,
                accessibilityIdentifier: "ChatPendingDiscard",
                action: { [actions, id = pending.id] in actions.discardPending(id) }
            ))
        }
        return stack
    }

    private func glyph(_ symbol: String, color: UIColor, label: String) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: symbol))
        view.preferredSymbolConfiguration = .init(textStyle: .caption2)
        view.tintColor = color
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        return view
    }

    private func actionButton(
        title: String,
        color: UIColor,
        weight: UIFont.Weight = .regular,
        accessibilityIdentifier: String,
        action: @escaping @MainActor () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: weight)
        button.accessibilityIdentifier = accessibilityIdentifier
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    private var bubbleOpacity: CGFloat {
        switch pending.delivery {
        case .queued: 0.6
        case .sending: 0.75
        case .delivered, .failed: 1
        }
    }
}

@MainActor
private final class ChatPendingPulseGlyph: UIImageView {
    init() {
        super.init(image: UIImage(systemName: "clock"))
        preferredSymbolConfiguration = .init(textStyle: .caption2)
        tintColor = .tertiaryLabel
        isAccessibilityElement = true
        accessibilityLabel = String(
            localized: "chat.pending.sending.accessibility",
            defaultValue: "Sending",
            bundle: .module
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layer.removeAnimation(forKey: "chat.pending.pulse")
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.3
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "chat.pending.pulse")
    }
}
#endif
