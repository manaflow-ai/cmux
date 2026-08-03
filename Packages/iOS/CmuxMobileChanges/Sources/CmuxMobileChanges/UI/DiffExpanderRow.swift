internal import Foundation

#if canImport(UIKit)
internal import UIKit

@MainActor
final class DiffExpanderCell: UITableViewCell {
    static let reuseIdentifier = "DiffExpanderCell"

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
        snapshot: DiffExpanderSnapshot,
        status: DiffExpansionRowStatus,
        interactionDisabled: Bool,
        theme: ChangesTheme,
        onExpand: @escaping @MainActor @Sendable (DiffExpanderSnapshot, DiffExpansionDirection) -> Void
    ) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let splitsDirections = snapshot.gap.directions.count > 1 && !snapshot.revealsCompletely
        let directions = splitsDirections || snapshot.gap.directions.count == 1
            ? snapshot.gap.directions
            : [.down]
        let unified = !splitsDirections && snapshot.gap.directions.count > 1

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.backgroundColor = theme.hunkHeaderBackground.uiColor.withAlphaComponent(0.72)
        stack.layer.borderColor = theme.gutterSeparator.uiColor.cgColor
        stack.layer.borderWidth = 0.5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
        ])

        for direction in directions {
            var configuration = UIButton.Configuration.plain()
            let loading = unified
                ? status == .loading(.down) || status == .loading(.up)
                : status == .loading(direction)
            configuration.image = loading
                ? nil
                : UIImage(systemName: unified ? "arrow.up.and.down" : (direction == .up ? "chevron.up" : "chevron.down"))
            configuration.showsActivityIndicator = loading
            configuration.title = visibleLabel(snapshot: snapshot, status: status, direction: direction)
            configuration.imagePadding = 7
            configuration.titleAlignment = .center
            configuration.baseForegroundColor = status == .tooLarge || status == .failed(direction)
                ? .secondaryLabel
                : theme.hunkHeaderText.uiColor
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
                onExpand(snapshot, direction)
            })
            button.isEnabled = !interactionDisabled && status != .tooLarge
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.titleLabel?.numberOfLines = 2
            button.accessibilityLabel = accessibilityLabel(
                snapshot: snapshot,
                status: status,
                direction: direction,
                unified: unified
            )
            stack.addArrangedSubview(button)
        }
    }

    private func visibleLabel(
        snapshot: DiffExpanderSnapshot,
        status: DiffExpansionRowStatus,
        direction: DiffExpansionDirection
    ) -> String {
        if status == .tooLarge {
            return String(localized: "changes.diff.expand.too_large", defaultValue: "Too large to expand", bundle: .module)
        }
        if status == .loading(direction) {
            return String(localized: "changes.diff.expand.loading", defaultValue: "Loading hidden lines…", bundle: .module)
        }
        if status == .failed(direction) {
            return String(
                localized: "changes.diff.expand.failed",
                defaultValue: "Couldn't expand lines. Tap to retry.",
                bundle: .module
            )
        }
        guard let count = snapshot.expansionLineCount else {
            return String(localized: "changes.diff.expand.hidden", defaultValue: "Expand hidden lines", bundle: .module)
        }
        return String(
            format: String(localized: "changes.diff.expand.count", defaultValue: "Expand %lld lines", bundle: .module),
            Int64(count)
        )
    }

    private func accessibilityLabel(
        snapshot: DiffExpanderSnapshot,
        status: DiffExpansionRowStatus,
        direction: DiffExpansionDirection,
        unified: Bool
    ) -> String {
        if status == .tooLarge { return visibleLabel(snapshot: snapshot, status: status, direction: direction) }
        if unified, let count = snapshot.expansionLineCount {
            return String(
                format: String(
                    localized: "changes.diff.expand.accessibility.all_count",
                    defaultValue: "Expand all %lld hidden lines",
                    bundle: .module
                ),
                Int64(count)
            )
        }
        guard let count = snapshot.expansionLineCount else {
            return String(
                localized: direction == .up
                    ? "changes.diff.expand.accessibility.above"
                    : "changes.diff.expand.accessibility.below",
                defaultValue: direction == .up ? "Expand hidden lines above" : "Expand hidden lines below",
                bundle: .module
            )
        }
        return String(
            format: String(
                localized: direction == .up
                    ? "changes.diff.expand.accessibility.above_count"
                    : "changes.diff.expand.accessibility.below_count",
                defaultValue: direction == .up
                    ? "Expand %lld hidden lines above"
                    : "Expand %lld hidden lines below",
                bundle: .module
            ),
            Int64(count)
        )
    }
}
#endif
