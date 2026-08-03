#if canImport(UIKit)
internal import UIKit

@MainActor
final class WorkspaceChangedFileCell: UITableViewCell {
    static let reuseIdentifier = "WorkspaceChangedFileCell"

    func configure(snapshot: ChangedFileRowSnapshot, theme: ChangesTheme, isPlaceholder: Bool = false) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = snapshot.file.displayFilename
        content.secondaryText = snapshot.file.kind == .renamed
            ? snapshot.file.path
            : snapshot.file.directoryPrefix
        content.textProperties.font = .preferredFont(forTextStyle: .body).withTraits(.traitBold)
        content.textProperties.color = snapshot.file.kind == .deleted ? .secondaryLabel : .label
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = snapshot.file.kind == .renamed ? 2 : 1
        content.prefersSideBySideTextAndSecondaryText = false

        let trailing = makeTrailingView(file: snapshot.file, theme: theme)
        accessoryView = trailing
        contentConfiguration = content
        selectionStyle = isPlaceholder ? .none : .default
        isUserInteractionEnabled = !isPlaceholder
        alpha = isPlaceholder ? 0.38 : 1
        accessibilityIdentifier = "MobileChangesRow-\(snapshot.file.path)"
        accessibilityLabel = snapshot.file.accessibilityLabel
    }

    private func makeTrailingView(file: ChangedFileItem, theme: ChangesTheme) -> UIView {
        if file.isBinary {
            let label = UILabel()
            label.text = String(localized: "changes.binary.badge", defaultValue: "BIN", bundle: .module)
            label.font = .preferredFont(forTextStyle: .caption2).withTraits(.traitBold)
            label.textColor = .secondaryLabel
            label.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.14)
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
                label.heightAnchor.constraint(equalToConstant: 20),
            ])
            return label
        }

        let additions = UILabel()
        additions.text = String(
            format: String(localized: "changes.summary.additions", defaultValue: "+%lld", bundle: .module),
            Int64(file.additions)
        )
        additions.textColor = theme.addedStatus.uiColor
        additions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let deletions = UILabel()
        deletions.text = String(
            format: String(localized: "changes.summary.deletions", defaultValue: "−%lld", bundle: .module),
            Int64(file.deletions)
        )
        deletions.textColor = theme.deletedStatus.uiColor
        deletions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let counts = UIStackView(arrangedSubviews: [additions, deletions])
        counts.axis = .horizontal
        counts.spacing = 5
        let stack = UIStackView(arrangedSubviews: [counts, ChangesMiniBar(
            additions: file.additions,
            deletions: file.deletions,
            theme: theme
        )])
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 5
        return stack
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
