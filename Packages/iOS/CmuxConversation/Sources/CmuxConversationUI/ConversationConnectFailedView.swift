#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Shown in place of the first-load spinner when no connection came within
/// the deadline (`ConversationConnectionState.failed`) and nothing is kept
/// to show: "Couldn't connect" and a Retry button.
final class ConversationConnectFailedView: UIView {
    var onRetry: (() -> Void)?
    let titleLabel = UILabel()
    let retryButton = UIButton(configuration: .plain())

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "conversation.connectFailed"
        titleLabel.text = String(localized: "conversation.connect.failed", defaultValue: "Couldn't connect", bundle: .module)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "conversation.connect.retry", defaultValue: "Retry", bundle: .module)
        retryButton.configuration = configuration
        retryButton.accessibilityIdentifier = "conversation.connect.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#endif
