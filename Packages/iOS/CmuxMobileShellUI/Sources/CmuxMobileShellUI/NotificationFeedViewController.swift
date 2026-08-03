#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import Observation
import UIKit

/// Store-free actions passed across the native feed controller boundary.
struct NotificationFeedActions {
    let open: @MainActor (MobileNotificationFeedItem) -> Void
    let markRead: @MainActor (MobileNotificationFeedItem) -> Void
    let markUnread: @MainActor (MobileNotificationFeedItem) -> Void
    let markAllRead: @MainActor () -> Void
    let refresh: @MainActor @Sendable () async -> Void
}

enum NotificationFeedEmptyState: Equatable {
    case loading
    case empty
    case allRead
    case noSearchResults
    case unavailable
    case requiresMacUpdate

    static func resolve(
        sourceItemCount: Int,
        filter: MobileNotificationFeedFilter,
        hasSearchQuery: Bool = false,
        isSourceRebuilding: Bool = false,
        status: MobileNotificationFeedStatus
    ) -> NotificationFeedEmptyState {
        if isSourceRebuilding { return .loading }
        if sourceItemCount > 0 {
            if hasSearchQuery { return .noSearchResults }
            if filter == .unread { return .allRead }
        }
        switch status {
        case .idle, .loading: return .loading
        case .unavailable: return .unavailable
        case .requiresMacUpdate: return .requiresMacUpdate
        case .ready: return hasSearchQuery ? .noSearchResults : .empty
        }
    }
}

/// UIKit notification feed with native refresh, swipe, context-menu, and search behavior.
@MainActor
final class NotificationFeedViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate,
    UISearchResultsUpdating
{
    private let projection: NotificationFeedProjection
    private var status: MobileNotificationFeedStatus
    private let actions: NotificationFeedActions
    private let refreshesOnAppear: Bool
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let filterControl = UISegmentedControl(items: [
        L10n.string("mobile.notificationFeed.filter.all", defaultValue: "All"),
        L10n.string("mobile.notificationFeed.filter.unread", defaultValue: "Unread"),
    ])
    private let emptyView = NotificationFeedNativeEmptyView()
    private let availabilityView = NotificationFeedAvailabilityView()
    private var sections: [NotificationFeedDaySection] = []
    private var projectionObservationGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var hasAppeared = false

    init(
        status: MobileNotificationFeedStatus,
        projection: NotificationFeedProjection,
        refreshesOnAppear: Bool,
        actions: NotificationFeedActions
    ) {
        self.status = status
        self.projection = projection
        self.refreshesOnAppear = refreshesOnAppear
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("mobile.notificationFeed.title", defaultValue: "Notifications")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { refreshTask?.cancel() }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground

        filterControl.selectedSegmentIndex = projection.filter == .unread ? 1 : 0
        filterControl.addTarget(self, action: #selector(filterChanged(_:)), for: .valueChanged)
        filterControl.accessibilityIdentifier = "MobileNotificationFeedFilter"
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 16)
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "MobileNotificationFeedList"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.register(NotificationFeedNativeCell.self, forCellReuseIdentifier: NotificationFeedNativeCell.reuseID)
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(refreshRequested(_:)), for: .valueChanged)

        root.addSubview(filterControl)
        root.addSubview(tableView)
        NSLayoutConstraint.activate([
            filterControl.leadingAnchor.constraint(equalTo: root.layoutMarginsGuide.leadingAnchor),
            filterControl.trailingAnchor.constraint(equalTo: root.layoutMarginsGuide.trailingAnchor),
            filterControl.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10),
            tableView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = L10n.string(
            "mobile.notificationFeed.search.placeholder",
            defaultValue: "Search notifications"
        )
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        observeProjection()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        if refreshesOnAppear { beginRefresh(showControl: false) }
    }

    func update(status: MobileNotificationFeedStatus) {
        guard self.status != status else { return }
        self.status = status
        applyProjectionSnapshot()
    }

    func updateSearchText(_ text: String) {
        if navigationItem.searchController?.searchBar.text != text {
            navigationItem.searchController?.searchBar.text = text
        }
        if projection.searchText != text { projection.searchText = text }
    }

    func updateSearchResults(for searchController: UISearchController) {
        projection.searchText = searchController.searchBar.text ?? ""
    }

    @objc private func filterChanged(_ sender: UISegmentedControl) {
        projection.filter = sender.selectedSegmentIndex == 1 ? .unread : .all
    }

    @objc private func refreshRequested(_ sender: UIRefreshControl) {
        beginRefresh(showControl: true)
    }

    private func beginRefresh(showControl: Bool) {
        refreshTask?.cancel()
        if showControl, tableView.refreshControl?.isRefreshing == false {
            tableView.refreshControl?.beginRefreshing()
        }
        let actions = actions
        refreshTask = Task { [weak self] in
            await actions.refresh()
            guard !Task.isCancelled else { return }
            self?.tableView.refreshControl?.endRefreshing()
        }
    }

    private func observeProjection() {
        projectionObservationGeneration &+= 1
        let generation = projectionObservationGeneration
        withObservationTracking {
            _ = projection.sections
            _ = projection.sourceItemCount
            _ = projection.sourceUnreadCount
            _ = projection.isSourceRebuilding
            _ = projection.hasStaleSourceSections
            _ = projection.hasMoreRows
            _ = projection.filter
            _ = projection.searchText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.projectionObservationGeneration == generation else { return }
                self.applyProjectionSnapshot()
                self.observeProjection()
            }
        }
        applyProjectionSnapshot()
    }

    private func applyProjectionSnapshot() {
        sections = projection.sections
        filterControl.selectedSegmentIndex = projection.filter == .unread ? 1 : 0
        updateMarkAllReadButton()
        updateHeader()
        updateEmptyState()
        tableView.isUserInteractionEnabled = !projection.hasStaleSourceSections
        tableView.alpha = projection.hasStaleSourceSections ? 0.65 : 1
        tableView.reloadData()
    }

    private func updateMarkAllReadButton() {
        navigationItem.rightBarButtonItem = projection.sourceUnreadCount > 0
            ? UIBarButtonItem(
                image: UIImage(systemName: "envelope.open"),
                primaryAction: UIAction(
                    title: L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read")
                ) { [weak self] _ in self?.actions.markAllRead() }
            )
            : nil
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "MobileNotificationFeedMarkAllRead"
    }

    private func updateHeader() {
        guard status == .unavailable || status == .requiresMacUpdate,
              projection.sourceItemCount > 0 else {
            tableView.tableHeaderView = nil
            return
        }
        availabilityView.configure(status: status)
        let width = max(1, tableView.bounds.width)
        let size = availabilityView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        availabilityView.frame = CGRect(x: 0, y: 0, width: width, height: max(64, size.height))
        tableView.tableHeaderView = availabilityView
    }

    private func updateEmptyState() {
        guard sections.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let state = NotificationFeedEmptyState.resolve(
            sourceItemCount: projection.sourceItemCount,
            filter: projection.filter,
            hasSearchQuery: !projection.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSourceRebuilding: projection.isSourceRebuilding,
            status: status
        )
        emptyView.configure(state: state) { [weak self] in self?.beginRefresh(showControl: false) }
        tableView.backgroundView = emptyView
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        return sections[section].items.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections.indices.contains(section) else { return nil }
        let model = sections[section]
        switch model.kind {
        case .today: return L10n.string("mobile.notificationFeed.day.today", defaultValue: "Today")
        case .yesterday: return L10n.string("mobile.notificationFeed.day.yesterday", defaultValue: "Yesterday")
        case .dated:
            return model.id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationFeedNativeCell.reuseID,
            for: indexPath
        ) as? NotificationFeedNativeCell,
              let model = model(at: indexPath) else { return UITableViewCell() }
        cell.configure(model: model)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = model(at: indexPath)?.item else { return }
        actions.open(item)
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = model(at: indexPath)?.item else { return nil }
        return UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil,
            actionProvider: { [weak self] _ in
            guard let self else { return UIMenu() }
            let open = UIAction(
                title: L10n.string("mobile.notificationFeed.open", defaultValue: "Open"),
                image: UIImage(systemName: "arrow.up.forward.app")
            ) { [actions] _ in actions.open(item) }
            let read = self.readAction(for: item)
                return UIMenu(children: [open, read])
            }
        )
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let item = model(at: indexPath)?.item else { return nil }
        let contextual = UIContextualAction(style: .normal, title: readActionTitle(for: item)) {
            [weak self] _, _, completion in
            self?.performReadAction(for: item)
            completion(true)
        }
        contextual.backgroundColor = .systemBlue
        contextual.image = UIImage(systemName: item.isRead ? "envelope.badge" : "envelope.open")
        let configuration = UISwipeActionsConfiguration(actions: [contextual])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard projection.hasMoreRows,
              scrollView.contentSize.height > 0,
              scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 180 else {
            return
        }
        projection.extendRowWindow()
    }

    private func model(at indexPath: IndexPath) -> NotificationFeedRowModel? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.row) else { return nil }
        return sections[indexPath.section].items[indexPath.row]
    }

    private func readAction(for item: MobileNotificationFeedItem) -> UIAction {
        UIAction(
            title: readActionTitle(for: item),
            image: UIImage(systemName: item.isRead ? "envelope.badge" : "envelope.open")
        ) { [weak self] _ in self?.performReadAction(for: item) }
    }

    private func readActionTitle(for item: MobileNotificationFeedItem) -> String {
        item.isRead
            ? L10n.string("mobile.notificationFeed.markUnread", defaultValue: "Mark as Unread")
            : L10n.string("mobile.notificationFeed.markRead", defaultValue: "Mark as Read")
    }

    private func performReadAction(for item: MobileNotificationFeedItem) {
        if item.isRead { actions.markUnread(item) } else { actions.markRead(item) }
    }
}

@MainActor
private final class NotificationFeedNativeCell: UITableViewCell {
    static let reuseID = "NotificationFeedNativeCell"
    private let unreadDot = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let provenanceLabel = UILabel()
    private let previewLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        unreadDot.layer.cornerRadius = 3
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 2
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        timeLabel.font = .preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        provenanceLabel.numberOfLines = 2
        provenanceLabel.font = .preferredFont(forTextStyle: .footnote)
        provenanceLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 3
        previewLabel.font = .preferredFont(forTextStyle: .footnote)
        previewLabel.textColor = .secondaryLabel

        let headline = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        headline.axis = .horizontal
        headline.alignment = .firstBaseline
        headline.spacing = 8
        let labels = UIStackView(arrangedSubviews: [headline, provenanceLabel, previewLabel])
        labels.axis = .vertical
        labels.spacing = 4
        let row = UIStackView(arrangedSubviews: [unreadDot, labels])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: NotificationFeedRowModel) {
        let item = model.item
        let presentation = model.presentation
        unreadDot.backgroundColor = item.isRead ? .clear : tintColor
        titleLabel.text = item.title
        titleLabel.font = item.isRead
            ? .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium)
            : .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        timeLabel.text = item.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        provenanceLabel.text = presentation.workspaceMatchesTitle
            ? "⌘ \(presentation.computerStatusText)"
            : "▣ \(presentation.workspaceName)   ⌘ \(presentation.computerStatusText)"
        previewLabel.text = presentation.contentPreview
        previewLabel.isHidden = presentation.contentPreview == nil
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = item.title
        accessibilityValue = (presentation.accessibilityDetails
            + [item.createdAt.formatted(.relative(presentation: .named))]).formatted()
        accessibilityHint = L10n.string(
            "mobile.notificationFeed.openHint",
            defaultValue: "Opens this notification's workspace."
        )
        accessibilityIdentifier = "MobileNotificationFeedRow-\(item.macDeviceID)-\(item.notificationID)"
    }
}

@MainActor
private final class NotificationFeedAvailabilityView: UIView {
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.tintColor = .systemOrange
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.font = .preferredFont(forTextStyle: .caption1)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, labels])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "MobileNotificationFeedAvailabilityBanner"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(status: MobileNotificationFeedStatus) {
        switch status {
        case .requiresMacUpdate:
            icon.image = UIImage(systemName: "arrow.down.circle")
            titleLabel.text = L10n.string("mobile.notificationFeed.update.title", defaultValue: "Update cmux on your Mac")
            bodyLabel.text = L10n.string(
                "mobile.notificationFeed.update.inlineBody",
                defaultValue: "Some paired Macs cannot sync notifications yet."
            )
        default:
            icon.image = UIImage(systemName: "wifi.slash")
            titleLabel.text = L10n.string("mobile.notificationFeed.offline.title", defaultValue: "Notifications are offline")
            bodyLabel.text = L10n.string(
                "mobile.notificationFeed.offline.inlineBody",
                defaultValue: "Showing the latest alerts synced from your Macs."
            )
        }
        accessibilityLabel = [titleLabel.text, bodyLabel.text].compactMap { $0 }.joined(separator: ". ")
    }
}

@MainActor
private final class NotificationFeedNativeEmptyView: UIView {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var retry: @MainActor () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 38, weight: .light)
        icon.tintColor = .systemBlue
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textAlignment = .center
        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        retryButton.configuration = .bordered()
        retryButton.setTitle(L10n.string("mobile.notificationFeed.retry", defaultValue: "Try Again"), for: .normal)
        retryButton.addTarget(self, action: #selector(retryPressed(_:)), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "MobileNotificationFeedRetry"
        let content = UIStackView(arrangedSubviews: [spinner, icon, titleLabel, bodyLabel, retryButton])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        accessibilityIdentifier = "MobileNotificationFeedEmptyState"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: NotificationFeedEmptyState, retry: @escaping @MainActor () -> Void) {
        self.retry = retry
        spinner.isHidden = state != .loading
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        icon.isHidden = state == .loading
        retryButton.isHidden = state != .unavailable && state != .requiresMacUpdate
        icon.image = UIImage(systemName: systemImage(for: state))
        icon.tintColor = state == .allRead
            ? .systemGreen
            : (state == .unavailable || state == .requiresMacUpdate ? .systemOrange : .systemBlue)
        titleLabel.text = title(for: state)
        bodyLabel.text = message(for: state)
        accessibilityLabel = [titleLabel.text, bodyLabel.text].compactMap { $0 }.joined(separator: ". ")
    }

    @objc private func retryPressed(_ sender: UIButton) { retry() }

    private func systemImage(for state: NotificationFeedEmptyState) -> String {
        switch state {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty: "bell.badge"
        case .allRead: "checkmark.circle"
        case .noSearchResults: "magnifyingglass"
        case .unavailable: "wifi.slash"
        case .requiresMacUpdate: "arrow.down.circle"
        }
    }

    private func title(for state: NotificationFeedEmptyState) -> String {
        switch state {
        case .loading: return L10n.string("mobile.notificationFeed.loading", defaultValue: "Syncing notifications…")
        case .empty: return L10n.string("mobile.notificationFeed.empty.title", defaultValue: "No notifications yet")
        case .allRead: return L10n.string("mobile.notificationFeed.allRead.title", defaultValue: "You're all caught up")
        case .noSearchResults:
            return L10n.string("mobile.notificationFeed.search.empty.title", defaultValue: "No matching notifications")
        case .unavailable:
            return L10n.string("mobile.notificationFeed.offline.title", defaultValue: "Notifications are offline")
        case .requiresMacUpdate:
            return L10n.string("mobile.notificationFeed.update.title", defaultValue: "Update cmux on your Mac")
        }
    }

    private func message(for state: NotificationFeedEmptyState) -> String {
        switch state {
        case .loading:
            return L10n.string("mobile.notificationFeed.loading.body", defaultValue: "Collecting agent alerts from your paired Macs.")
        case .empty:
            return L10n.string(
                "mobile.notificationFeed.empty.body",
                defaultValue: "Every agent alert from your paired Macs will collect here, even if push alerts are off. Enable push alerts in Settings only when you want an immediate heads-up away from the app."
            )
        case .allRead:
            return L10n.string("mobile.notificationFeed.allRead.body", defaultValue: "New agent alerts will appear here as they arrive.")
        case .noSearchResults:
            return L10n.string(
                "mobile.notificationFeed.search.empty.body",
                defaultValue: "Try another title, message, workspace, pane, or computer."
            )
        case .unavailable:
            return L10n.string("mobile.notificationFeed.offline.body", defaultValue: "Reconnect a paired Mac, then pull to refresh.")
        case .requiresMacUpdate:
            return L10n.string(
                "mobile.notificationFeed.update.body",
                defaultValue: "Install the latest cmux on your paired Macs to sync their notification history."
            )
        }
    }
}
#endif
