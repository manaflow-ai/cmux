internal import Foundation

#if canImport(UIKit)
internal import UIKit

@MainActor
final class FileDiffContinuationCell: UITableViewCell {
    static let reuseIdentifier = "FileDiffContinuationCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        continuation: FileDiffContinuation,
        state: FileDiffContinuationLoadState,
        onShowMore: @escaping @MainActor @Sendable () -> Void
    ) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let message = UILabel()
        message.font = .preferredFont(forTextStyle: .footnote)
        message.textColor = .secondaryLabel
        message.textAlignment = .center
        message.numberOfLines = 0

        if continuation.canShowMore {
            if let total = continuation.totalLineCount {
                message.text = String(
                    format: String(
                        localized: "changes.diff.progress",
                        defaultValue: "Showing %1$@ of %2$@ diff lines",
                        bundle: .module
                    ),
                    continuation.shownLineCount.formatted(),
                    total.formatted()
                )
            } else {
                message.text = String(
                    format: String(
                        localized: "changes.diff.progress_loaded_only",
                        defaultValue: "Showing the first %@ diff lines",
                        bundle: .module
                    ),
                    continuation.shownLineCount.formatted()
                )
            }
            stack.addArrangedSubview(message)

            var configuration = UIButton.Configuration.plain()
            configuration.title = String(localized: "changes.diff.show_more", defaultValue: "Show more", bundle: .module)
            configuration.showsActivityIndicator = state == .loading
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in onShowMore() })
            button.isEnabled = state != .loading
            stack.addArrangedSubview(button)

            if state == .failed {
                let error = UILabel()
                error.text = String(
                    localized: "changes.diff.show_more_failed",
                    defaultValue: "Couldn't load more diff lines. Try again.",
                    bundle: .module
                )
                error.font = .preferredFont(forTextStyle: .footnote)
                error.textColor = .systemRed
                error.textAlignment = .center
                error.numberOfLines = 0
                stack.addArrangedSubview(error)
            }
        } else {
            message.text = String(
                format: String(
                    localized: "changes.diff.truncated",
                    defaultValue: "Large diff. Showing the first %lld lines to keep things fast. See the rest on your Mac.",
                    bundle: .module
                ),
                Int64(continuation.shownLineCount)
            )
            stack.addArrangedSubview(message)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }
}
#endif
