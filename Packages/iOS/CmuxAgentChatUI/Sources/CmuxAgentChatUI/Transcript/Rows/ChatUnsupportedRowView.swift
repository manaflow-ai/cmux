import CmuxAgentChat

#if canImport(UIKit)
import UIKit

/// Native fail-open caption for an unsupported wire payload.
@MainActor
public final class ChatUnsupportedRowView: UIView {
    public init(payload: ChatUnsupportedPayload) {
        super.init(frame: .zero)
        let label = UILabel()
        label.text = String(
            localized: "chat.unsupported",
            defaultValue: "Unsupported message (\(payload.rawType))",
            bundle: .module
        )
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
}
#endif
