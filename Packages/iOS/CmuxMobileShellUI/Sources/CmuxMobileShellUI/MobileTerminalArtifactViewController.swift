#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileToast
import Foundation
import UIKit

/// Native terminal and session artifact browser.
@MainActor
final class MobileTerminalArtifactViewController: UITableViewController, UISearchResultsUpdating {
    private enum Scope: Int {
        case session
        case inView
    }

    private struct Row {
        let path: String
        let displayName: String
        let kind: ChatArtifactKind
        let size: Int64?
        let exists: Bool
        let subtitle: String?
        let loader: ChatArtifactLoader
        let viewerScope: ChatArtifactViewerScope
        let swipeOrder: ChatArtifactGallerySwipeOrder

    }

    private let store: CMUXMobileShellStore
    private let workspaceID: String
    private let surfaceID: String
    private let toastCenter: ToastCenter
    private let thumbnailCache = ChatArtifactThumbnailCache()
    private let scopeControl = UISegmentedControl(items: [
        L10n.string("terminal.artifact.gallery.scope.session", defaultValue: "Session"),
        L10n.string("terminal.artifact.gallery.scope.in_view", defaultValue: "In View"),
    ])
    private let searchController = UISearchController(searchResultsController: nil)
    private var scope: Scope = .inView
    private var inViewRows: [Row] = []
    private var sessionRows: [Row] = []
    private var sessionID: String?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var isLoading = false
    private var didFail = false

    init(
        store: CMUXMobileShellStore,
        workspaceID: String,
        surfaceID: String,
        toastCenter: ToastCenter
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.toastCenter = toastCenter
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        loadTask?.cancel()
        searchTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("terminal.artifact.gallery.title", defaultValue: "Files")
        view.accessibilityIdentifier = "MobileTerminalArtifactGallery"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "artifact")
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)

        scopeControl.selectedSegmentIndex = Scope.inView.rawValue
        scopeControl.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        scopeControl.accessibilityIdentifier = "MobileTerminalArtifactScope"
        navigationItem.titleView = scopeControl

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L10n.string(
            "terminal.artifact.gallery.search",
            defaultValue: "Search session files"
        )
        searchController.searchBar.accessibilityIdentifier = "MobileTerminalArtifactSearch"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = true

        let done = UIBarButtonItem(
            title: L10n.string("terminal.artifact.gallery.done", defaultValue: "Done"),
            style: .done,
            target: self,
            action: #selector(donePressed)
        )
        done.accessibilityIdentifier = "MobileTerminalArtifactDone"
        navigationItem.rightBarButtonItem = done
        load()
    }

    @objc private func donePressed() {
        dismiss(animated: true)
    }

    @objc private func refresh() {
        load(query: activeQuery)
    }

    @objc private func scopeChanged() {
        scope = Scope(rawValue: scopeControl.selectedSegmentIndex) ?? .inView
        navigationItem.searchController = scope == .session ? searchController : nil
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        searchTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.load(query: query)
        }
    }

    private var activeQuery: String? {
        guard scope == .session else { return nil }
        let value = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func load(query: String? = nil) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadNow(query: query) }
    }

    private func loadNow(query: String?) async {
        guard let source = store.makeChatEventSource() else {
            didFail = true
            isLoading = false
            render()
            return
        }
        isLoading = true
        didFail = false
        render()
        do {
            if query == nil {
                let response = try await source.terminalArtifactScan(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    visibleOnly: true
                )
                try Task.checkCancellation()
                sessionID = response.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                let references = store.supportsTerminalArtifactList
                    ? response.artifacts
                    : response.artifacts.filter { $0.kind != .directory }
                let order = ChatArtifactGallerySwipeOrder(references: references)
                let loader = terminalLoader(source: source)
                inViewRows = references.map { reference in
                    Row(
                        path: reference.path,
                        displayName: reference.displayName,
                        kind: reference.kind,
                        size: reference.size,
                        exists: true,
                        subtitle: reference.path,
                        loader: loader,
                        viewerScope: .terminal,
                        swipeOrder: order
                    )
                }
            }

            if source.supportsArtifactGallery,
               let sessionID,
               !sessionID.isEmpty {
                let page = try await source.chatArtifactGallery(
                    sessionID: sessionID,
                    cursor: nil,
                    pageSize: 200,
                    query: query
                )
                try Task.checkCancellation()
                let items = page.created + page.attached + page.referenced
                let visible = store.supportsTerminalArtifactList
                    ? items
                    : items.filter { $0.kind != .directory }
                let order = ChatArtifactGallerySwipeOrder(items: visible)
                let loader = ChatArtifactLoader(
                    source: source,
                    sessionID: sessionID,
                    cache: thumbnailCache
                )
                sessionRows = visible.map { item in
                    Row(
                        path: item.path,
                        displayName: item.displayName,
                        kind: item.kind,
                        size: item.size,
                        exists: item.exists,
                        subtitle: item.exists ? item.path : L10n.string(
                            "terminal.artifact.gallery.missing",
                            defaultValue: "Missing on Mac"
                        ),
                        loader: loader,
                        viewerScope: .chat,
                        swipeOrder: order
                    )
                }
                if query == nil { scope = .session }
            } else if query == nil {
                sessionRows = []
                scope = .inView
            }
            didFail = false
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
        isLoading = false
        refreshControl?.endRefreshing()
        render()
    }

    private func terminalLoader(source: MobileChatEventSource) -> ChatArtifactLoader {
        ChatArtifactLoader(
            terminalWorkspaceID: workspaceID,
            terminalSurfaceID: surfaceID,
            supportsArtifacts: store.supportsTerminalArtifacts,
            supportsDirectoryBrowsing: store.supportsTerminalArtifactList,
            cache: thumbnailCache,
            stat: { [workspaceID, surfaceID] path in
                try await source.terminalArtifactStat(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            },
            fetch: { [workspaceID, surfaceID] path, progress in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    progress: progress
                )
            },
            stream: { [workspaceID, surfaceID] path, onChunk in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    onChunk: onChunk
                )
            },
            thumbnail: { [workspaceID, surfaceID] path, maxDimension in
                try await source.terminalArtifactThumbnail(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    maxDimension: maxDimension
                )
            },
            list: { [workspaceID, surfaceID] path in
                try await source.terminalArtifactList(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            }
        )
    }

    private var rows: [Row] {
        scope == .session && sessionID != nil ? sessionRows : inViewRows
    }

    private func render() {
        guard isViewLoaded else { return }
        let hasSession = sessionID?.isEmpty == false
        scopeControl.isHidden = !hasSession
        scopeControl.selectedSegmentIndex = (hasSession ? scope : .inView).rawValue
        navigationItem.searchController = hasSession && scope == .session ? searchController : nil
        tableView.reloadData()

        if isLoading && rows.isEmpty {
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.startAnimating()
            tableView.backgroundView = spinner
        } else if didFail && rows.isEmpty {
            tableView.backgroundView = unavailableView(
                title: L10n.string("terminal.artifact.gallery.failed", defaultValue: "Couldn't load files"),
                symbol: "exclamationmark.triangle"
            )
        } else if rows.isEmpty {
            tableView.backgroundView = unavailableView(
                title: scope == .session
                    ? L10n.string("terminal.artifact.gallery.session_empty", defaultValue: "No files in this session")
                    : L10n.string("terminal.artifact.gallery.empty", defaultValue: "No files in view"),
                symbol: "tray"
            )
        } else {
            tableView.backgroundView = nil
        }
    }

    private func unavailableView(title: String, symbol: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = .secondaryLabel
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34)
        let label = UILabel()
        label.text = title
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .headline)
        label.numberOfLines = 0
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [image, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        let root = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
        ])
        return root
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "artifact", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = row.displayName
        content.secondaryText = row.subtitle
        content.secondaryTextProperties.numberOfLines = 1
        content.image = UIImage(systemName: symbol(for: row.kind))
        content.imageProperties.tintColor = row.exists ? .secondaryLabel : .tertiaryLabel
        content.textProperties.color = row.exists ? .label : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "MobileTerminalArtifact-\(row.path)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        guard row.exists else { return }
        let controller = ChatArtifactViewerController(
            path: row.path,
            scope: row.viewerScope,
            swipeOrder: row.swipeOrder,
            loader: row.loader,
            toastCenter: toastCenter,
            onDone: { [weak self] in self?.navigationController?.popViewController(animated: true) }
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func symbol(for kind: ChatArtifactKind) -> String {
        switch kind {
        case .image: "photo"
        case .text: "doc.text"
        case .binary: "doc"
        case .directory: "folder"
        }
    }
}
#endif
