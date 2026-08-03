import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native permission card that atomically disarms after one decision.
@MainActor
public final class ChatPermissionCardView: UIView {
    private let actions: ChatRowActions
    private var decisionButtons: [UIButton] = []
    private var tappedIndex: Int?

    public init(
        request: ChatPermissionRequest,
        timestamp: Date,
        actions: ChatRowActions
    ) {
        self.actions = actions
        super.init(frame: .zero)

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10

        let title = UILabel()
        title.text = request.title
        title.font = .preferredFont(forTextStyle: .subheadline).weighted(.semibold)
        title.textColor = .label
        title.numberOfLines = 0
        content.addArrangedSubview(title)
        content.addArrangedSubview(subjectView(request.subject))

        if let resolution = request.resolution {
            content.addArrangedSubview(receiptView(resolution: resolution, timestamp: timestamp))
        } else {
            let approve = decisionButton(
                title: String(
                    localized: "chat.permission.approve",
                    defaultValue: "Approve",
                    bundle: .module
                ),
                index: 0,
                filled: true,
                accessibilityIdentifier: "ChatPermissionApprove"
            )
            let deny = decisionButton(
                title: String(
                    localized: "chat.permission.deny",
                    defaultValue: "Deny",
                    bundle: .module
                ),
                index: 1,
                filled: false,
                accessibilityIdentifier: "ChatPermissionDeny"
            )
            decisionButtons = [approve, deny]
            let decisions = UIStackView(arrangedSubviews: decisionButtons)
            decisions.axis = .vertical
            decisions.spacing = 8
            content.addArrangedSubview(decisions)
        }

        let card = UIView()
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1.5
        card.layer.borderColor = UIColor.systemBlue.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func subjectView(_ subject: String) -> UIView {
        let label = UILabel()
        label.text = subject
        label.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        label.textColor = UIColor(white: 0.88, alpha: 1)
        label.numberOfLines = 0
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.055, alpha: 1)
        container.layer.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])
        return container
    }

    private func decisionButton(
        title: String,
        index: Int,
        filled: Bool,
        accessibilityIdentifier: String
    ) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = filled ? UIButton.Configuration.filled() : UIButton.Configuration.bordered()
        configuration.title = title
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 10
        configuration.baseBackgroundColor = filled ? .systemBlue : .clear
        configuration.baseForegroundColor = filled ? .white : .label
        button.configuration = configuration
        button.accessibilityIdentifier = accessibilityIdentifier
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.decide(index) }, for: .primaryActionTriggered)
        return button
    }

    private func decide(_ index: Int) {
        guard tappedIndex == nil else { return }
        tappedIndex = index
        for button in decisionButtons {
            button.isEnabled = false
            button.alpha = 0.6
        }
        var configuration = decisionButtons[index].configuration
        configuration?.showsActivityIndicator = true
        decisionButtons[index].configuration = configuration
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        actions.answerOption(index)
    }

    private func receiptView(
        resolution: ChatPermissionRequest.Resolution,
        timestamp: Date
    ) -> UIView {
        let symbol: String
        let text: String
        switch resolution {
        case .approved:
            symbol = "checkmark"
            text = String(localized: "chat.permission.approved", defaultValue: "Approved", bundle: .module)
        case .denied:
            symbol = "xmark"
            text = String(localized: "chat.permission.denied", defaultValue: "Denied", bundle: .module)
        case .expired:
            symbol = "clock"
            text = String(localized: "chat.permission.expired", defaultValue: "Expired", bundle: .module)
        }
        let label = UILabel()
        label.text = "\(text) · \(timestamp.formatted(.dateTime.hour().minute()))"
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [icon, label, UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        return stack
    }
}

private extension UIFont {
    func weighted(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
#endif
