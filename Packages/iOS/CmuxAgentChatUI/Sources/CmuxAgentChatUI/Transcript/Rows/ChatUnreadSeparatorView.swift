#if canImport(UIKit)
import UIKit

/// Native unread-message separator with an accent hairline and caption.
@MainActor
public final class ChatUnreadSeparatorView: UIView {
    public init(accentColor: UIColor = .systemBlue) {
        super.init(frame: .zero)

        let label = UILabel()
        label.text = String(
            localized: "chat.unread_separator",
            defaultValue: "Unread messages",
            bundle: .module
        )
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = accentColor
        label.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [hairline(color: accentColor), label, hairline(color: accentColor)])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func hairline(color: UIColor) -> UIView {
        let view = UIView()
        view.backgroundColor = color.withAlphaComponent(0.4)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return view
    }
}
#endif
