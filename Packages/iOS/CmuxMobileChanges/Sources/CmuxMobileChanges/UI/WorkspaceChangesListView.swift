internal import Foundation

#if canImport(UIKit)
public import UIKit

/// Native changed-file list with pull-to-refresh and immutable row snapshots.
@MainActor
public final class WorkspaceChangesListViewController: UITableViewController {
    private var branch: String
    private var base: String
    private var totals: ChangesTotals
    private var files: [ChangedFileItem]
    private var state: WorkspaceChangesListState
    private var actions: WorkspaceChangesListActions
    private var theme: ChangesTheme
    private var summaryHeader: WorkspaceChangesSummaryHeader?

    public init(
        branch: String,
        base: String,
        totals: ChangesTotals,
        files: [ChangedFileItem],
        state: WorkspaceChangesListState,
        actions: WorkspaceChangesListActions
    ) {
        self.branch = branch
        self.base = base
        self.totals = totals
        self.files = files
        self.state = state
        self.actions = actions
        theme = ChangesTheme(appearance: .light)
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "MobileChangesList"
        tableView.register(
            WorkspaceChangedFileCell.self,
            forCellReuseIdentifier: WorkspaceChangedFileCell.reuseIdentifier
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 58
        tableView.keyboardDismissMode = .onDrag
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.actions.onRefresh()
                self.refreshControl?.endRefreshing()
            }
        }, for: .valueChanged)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: WorkspaceChangesListViewController, _) in
            controller.render()
        }
        render()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeSummaryHeader()
    }

    /// Reconciles immutable list input without replacing the controller or scroll view.
    public func update(
        branch: String,
        base: String,
        totals: ChangesTotals,
        files: [ChangedFileItem],
        state: WorkspaceChangesListState,
        actions: WorkspaceChangesListActions
    ) {
        self.branch = branch
        self.base = base
        self.totals = totals
        self.files = files
        self.state = state
        self.actions = actions
        guard isViewLoaded else { return }
        render()
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch state {
        case .loading:
            7
        case .loaded:
            files.count
        case .error, .empty, .notARepository:
            0
        }
    }

    public override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: WorkspaceChangedFileCell.reuseIdentifier,
            for: indexPath
        ) as! WorkspaceChangedFileCell
        switch state {
        case .loading:
            cell.configure(
                snapshot: ChangedFileRowSnapshot(
                    index: indexPath.row,
                    file: ChangedFileItem(
                        path: "Sources/PlaceholderFile.swift",
                        kind: .modified,
                        additions: 12,
                        deletions: 3,
                        isBinary: false
                    )
                ),
                theme: theme,
                isPlaceholder: true
            )
        case .loaded:
            cell.configure(
                snapshot: ChangedFileRowSnapshot(index: indexPath.row, file: files[indexPath.row]),
                theme: theme
            )
        case .error, .empty, .notARepository:
            break
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .loaded = state, files.indices.contains(indexPath.row) else { return }
        actions.onSelectFile(indexPath.row)
    }

    func render() {
        theme = ChangesTheme(traitCollection: traitCollection)
        configureHeader()
        configureUnavailableView()
        configureFooter()
        tableView.reloadData()
    }

    private func configureHeader() {
        guard state != .notARepository else {
            summaryHeader = nil
            tableView.tableHeaderView = nil
            return
        }
        let header = WorkspaceChangesSummaryHeader(
            branch: branch,
            base: base,
            totals: totals,
            theme: theme
        )
        summaryHeader = header
        tableView.tableHeaderView = header
        sizeSummaryHeader()
    }

    private func sizeSummaryHeader() {
        guard let summaryHeader else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = summaryHeader.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if summaryHeader.frame.width != width || summaryHeader.frame.height != size.height {
            summaryHeader.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
            tableView.tableHeaderView = summaryHeader
        }
    }

    private func configureUnavailableView() {
        let unavailable: ChangesUnavailableView?
        switch state {
        case .error:
            unavailable = ChangesUnavailableView(
                systemImage: "exclamationmark.triangle",
                title: String(localized: "changes.error.title", defaultValue: "Couldn't load changes", bundle: .module),
                message: String(
                    localized: "changes.error.message",
                    defaultValue: "Check the connection to your Mac and try again.",
                    bundle: .module
                ),
                buttonTitle: String(localized: "changes.retry", defaultValue: "Retry", bundle: .module),
                action: actions.onRetry
            )
        case .empty:
            unavailable = ChangesUnavailableView(
                systemImage: "doc.text.magnifyingglass",
                title: String(localized: "changes.empty.title", defaultValue: "No changes", bundle: .module),
                message: String(
                    format: String(
                        localized: "changes.empty.message",
                        defaultValue: "This workspace matches %@.",
                        bundle: .module
                    ),
                    base
                )
            )
        case .notARepository:
            unavailable = ChangesUnavailableView(
                systemImage: "folder.badge.questionmark",
                title: String(
                    localized: "changes.not_repo.title",
                    defaultValue: "Not a Git repository",
                    bundle: .module
                ),
                message: String(
                    localized: "changes.not_repo.message",
                    defaultValue: "This workspace's directory isn't inside a Git repository.",
                    bundle: .module
                )
            )
        case .loading, .loaded:
            unavailable = nil
        }
        tableView.backgroundView = unavailable
    }

    private func configureFooter() {
        guard case .loaded(truncated: true) = state else {
            tableView.tableFooterView = UIView(frame: .zero)
            return
        }
        let label = UILabel()
        label.text = String(
            localized: "changes.files.truncated",
            defaultValue: "Showing the first 500 changed files. See the rest on your Mac.",
            bundle: .module
        )
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.frame = CGRect(x: 16, y: 10, width: max(0, tableView.bounds.width - 32), height: 52)
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72))
        footer.addSubview(label)
        label.autoresizingMask = [.flexibleWidth]
        tableView.tableFooterView = footer
    }
}

@MainActor
final class ChangesUnavailableView: UIView {
    init(
        systemImage: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (@MainActor @Sendable () -> Void)? = nil
    ) {
        super.init(frame: .zero)
        let imageView = UIImageView(image: UIImage(systemName: systemImage))
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var views: [UIView] = [imageView, titleLabel, messageLabel]
        if let buttonTitle, let action {
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = buttonTitle
            views.append(UIButton(configuration: configuration, primaryAction: UIAction { _ in action() }))
        }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
