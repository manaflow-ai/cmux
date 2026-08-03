#if canImport(UIKit)
internal import UIKit

@MainActor
final class WorkspaceChangesSummaryHeader: UIView {
    init(branch: String, base: String, totals: ChangesTotals, theme: ChangesTheme) {
        super.init(frame: .zero)
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16)

        let files = UILabel()
        files.text = String(
            format: String(
                localized: "changes.summary.files_changed",
                defaultValue: "%lld files changed",
                bundle: .module
            ),
            Int64(totals.filesChanged)
        )
        files.font = .preferredFont(forTextStyle: .headline)

        let additions = UILabel()
        additions.text = String(
            format: String(localized: "changes.summary.additions", defaultValue: "+%lld", bundle: .module),
            Int64(totals.additions)
        )
        additions.textColor = theme.addedStatus.uiColor
        additions.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)

        let deletions = UILabel()
        deletions.text = String(
            format: String(localized: "changes.summary.deletions", defaultValue: "−%lld", bundle: .module),
            Int64(totals.deletions)
        )
        deletions.textColor = theme.deletedStatus.uiColor
        deletions.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)

        let counts = UIStackView(arrangedSubviews: [additions, deletions])
        counts.axis = .horizontal
        counts.spacing = 8
        let top = UIStackView(arrangedSubviews: [files, UIView(), counts])
        top.axis = .horizontal
        top.alignment = .firstBaseline
        top.spacing = 12

        let branchLabel = UILabel()
        branchLabel.text = "⑂ " + String(
            format: String(
                localized: "changes.summary.branch_base",
                defaultValue: "%1$@ ← %2$@",
                bundle: .module
            ),
            branch,
            base
        )
        branchLabel.font = .preferredFont(forTextStyle: .subheadline)
        branchLabel.textColor = .secondaryLabel
        branchLabel.lineBreakMode = .byTruncatingMiddle

        let stack = UIStackView(arrangedSubviews: [top, branchLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(files.text ?? ""), \(branchLabel.text ?? "")"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
