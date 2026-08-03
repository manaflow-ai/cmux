#if canImport(UIKit)
import UIKit

/// Native collapsed reasoning row that opens the full detail surface.
@MainActor
public final class ChatThoughtRowView: UIControl {
    private let onShowDetail: @MainActor () -> Void

    public init(rowID: String, onShowDetail: @escaping @MainActor () -> Void = {}) {
        self.onShowDetail = onShowDetail
        super.init(frame: .zero)

        let brain = UIImageView(image: UIImage(systemName: "brain"))
        brain.preferredSymbolConfiguration = .init(textStyle: .caption1)
        let label = UILabel()
        label.text = String(localized: "chat.thought.title", defaultValue: "Thought", bundle: .module)
        label.font = .preferredFont(forTextStyle: .caption1).italicized
        let detail = UIImageView(image: UIImage(systemName: "doc.text.magnifyingglass"))
        detail.preferredSymbolConfiguration = .init(textStyle: .caption2)

        let stack = UIStackView(arrangedSubviews: [brain, label, detail, UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        tintColor = .secondaryLabel
        accessibilityIdentifier = "ChatThoughtDetail-\(rowID)"
        accessibilityLabel = label.text
        accessibilityHint = String(
            localized: "chat.detail.show.hint",
            defaultValue: "Opens a sheet with the full block content",
            bundle: .module
        )
        addTarget(self, action: #selector(showDetail), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showDetail() {
        onShowDetail()
    }
}

private extension UIFont {
    var italicized: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
