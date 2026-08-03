import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native centered caption for a durable session lifecycle transition.
@MainActor
public final class ChatStatusRowView: UIView {
    public init(transition: ChatStatusTransition, timestamp _: Date) {
        super.init(frame: .zero)
        let label = UILabel()
        let base = Self.eventLabel(transition.event)
        if let detail = transition.detail, !detail.isEmpty {
            label.text = "\(base) · \(detail)"
        } else {
            label.text = base
        }
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func eventLabel(_ event: ChatStatusTransition.Event) -> String {
        switch event {
        case .sessionStarted:
            String(localized: "chat.status.session_started", defaultValue: "Session started", bundle: .module)
        case .sessionEnded:
            String(localized: "chat.status.session_ended", defaultValue: "Session ended", bundle: .module)
        case .interrupted:
            String(localized: "chat.status.interrupted", defaultValue: "Interrupted", bundle: .module)
        case .contextCompacted:
            String(localized: "chat.status.context_compacted", defaultValue: "Context compacted", bundle: .module)
        }
    }
}
#endif
