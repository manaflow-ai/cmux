#if canImport(UIKit)
internal import UIKit

/// Five-segment native magnitude bar used by changed-file rows.
@MainActor
final class ChangesMiniBar: UIStackView {
    init(additions: Int, deletions: Int, theme: ChangesTheme) {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 2
        isAccessibilityElement = false

        let filledCount = min(5, additions + deletions)
        let total = additions + deletions
        let additionCount = total > 0
            ? min(filledCount, Int((Double(additions) / Double(total) * Double(filledCount)).rounded()))
            : 0
        for index in 0..<5 {
            let segment = UIView()
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.layer.cornerRadius = 1
            segment.backgroundColor = if index >= filledCount {
                UIColor.secondaryLabel.withAlphaComponent(0.18)
            } else if index < additionCount {
                theme.addedStatus.uiColor
            } else {
                theme.deletedStatus.uiColor
            }
            addArrangedSubview(segment)
            NSLayoutConstraint.activate([
                segment.widthAnchor.constraint(equalToConstant: 3),
                segment.heightAnchor.constraint(equalToConstant: 8),
            ])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
