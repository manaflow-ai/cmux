#if canImport(UIKit)
import UIKit

/// Native centered day-boundary pill ("Today", "Yesterday", or a date).
@MainActor
public final class ChatDateHeaderView: UIView {
    private static let relativeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    public init(day: Date) {
        super.init(frame: .zero)

        let label = UILabel()
        label.text = Self.relativeDayFormatter.string(from: day)
        label.font = .preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.accessibilityIdentifier = "ChatDateHeader"
        let pill = UIView()
        pill.backgroundColor = .secondarySystemFill
        pill.layer.cornerRadius = 11
        pill.layer.masksToBounds = true
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
