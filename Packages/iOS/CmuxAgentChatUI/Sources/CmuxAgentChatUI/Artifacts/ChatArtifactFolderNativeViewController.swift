#if os(iOS)
import CmuxAgentChat
import UIKit

/// Native, cancellable browser for one immediate artifact directory listing.
@MainActor
final class ChatArtifactFolderNativeViewController: UITableViewController {
    private let path: String
    private let scope: ChatArtifactViewerScope
    private let loader: ChatArtifactLoader
    private let onSelect: @MainActor (ChatArtifactFolderRoute) -> Void
    private var listing: ChatArtifactDirectoryListing?
    private var loadTask: Task<Void, Never>?
    private let breadcrumbLabel = UILabel()

    init(
        path: String,
        scope: ChatArtifactViewerScope,
        loader: ChatArtifactLoader,
        onSelect: @escaping @MainActor (ChatArtifactFolderRoute) -> Void
    ) {
        self.path = path
        self.scope = scope
        self.loader = loader
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(ChatArtifactFolderCell.self, forCellReuseIdentifier: ChatArtifactFolderCell.reuseIdentifier)
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = .systemBackground

        breadcrumbLabel.text = parentPath
        breadcrumbLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        breadcrumbLabel.textColor = .secondaryLabel
        breadcrumbLabel.lineBreakMode = .byTruncatingMiddle
        breadcrumbLabel.accessibilityLabel = path
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 40))
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(breadcrumbLabel)
        NSLayoutConstraint.activate([
            breadcrumbLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            breadcrumbLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        tableView.tableHeaderView = header
        showLoadingState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if listing == nil, loadTask == nil {
            load()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        loadTask = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView,
              header.frame.width != tableView.bounds.width else { return }
        header.frame.size.width = tableView.bounds.width
        tableView.tableHeaderView = header
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        listing == nil ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        listing?.entries.count ?? 0
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatArtifactFolderCell.reuseIdentifier,
            for: indexPath
        ) as? ChatArtifactFolderCell,
            let entry = listing?.entries[indexPath.row] else {
            return UITableViewCell()
        }
        cell.configure(
            entry: entry,
            path: childPath(named: entry.name),
            loader: loader
        )
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = listing?.entries[indexPath.row] else { return }
        onSelect(ChatArtifactFolderRoute(
            parentPath: path,
            childName: entry.name,
            scope: scope,
            loader: loader
        ))
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        guard listing?.isTruncated == true else { return nil }
        return String(
            localized: "chat.artifact.folder.showing_first_500",
            defaultValue: "Showing first 500 items",
            bundle: .module
        )
    }

    private func load() {
        loadTask?.cancel()
        showLoadingState()
        loadTask = Task { [weak self, loader, path] in
            do {
                let listing = try await loader.list(path: path)
                try Task.checkCancellation()
                guard let self else { return }
                self.listing = listing
                self.loadTask = nil
                self.tableView.reloadData()
                self.updateEmptyState()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.loadTask = nil
                self.showFailureState()
            }
        }
    }

    private func showLoadingState() {
        let progress = UIActivityIndicatorView(style: .medium)
        progress.startAnimating()
        tableView.backgroundView = progress
    }

    private func updateEmptyState() {
        guard listing?.entries.isEmpty == true else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = String(
            localized: "chat.artifact.folder.empty",
            defaultValue: "No items",
            bundle: .module
        )
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        tableView.backgroundView = label
    }

    private func showFailureState() {
        let title = UILabel()
        title.text = String(
            localized: "chat.artifact.folder.load_failed",
            defaultValue: "Couldn't load this folder",
            bundle: .module
        )
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 0

        let retry = UIButton(type: .system)
        var configuration = UIButton.Configuration.bordered()
        configuration.title = String(
            localized: "chat.artifact.retry",
            defaultValue: "Retry",
            bundle: .module
        )
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 6
        retry.configuration = configuration
        retry.addTarget(self, action: #selector(retryLoad), for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [title, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        let container = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        tableView.backgroundView = container
    }

    @objc private func retryLoad() {
        load()
    }

    private func childPath(named name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    private var parentPath: String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

@MainActor
private final class ChatArtifactFolderCell: UITableViewCell {
    static let reuseIdentifier = "ChatArtifactFolderCell"

    private var thumbnailTask: Task<Void, Never>?
    private var representedPath: String?

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedPath = nil
    }

    func configure(
        entry: ChatArtifactDirectoryEntry,
        path: String,
        loader: ChatArtifactLoader
    ) {
        thumbnailTask?.cancel()
        representedPath = path
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.name
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        if !entry.isDirectory {
            content.secondaryText = ByteCountFormatter.string(
                fromByteCount: entry.size,
                countStyle: .file
            )
        }
        let kind: ChatArtifactKind = entry.isDirectory ? .directory : entry.kind
        let glyph = ChatArtifactGalleryClassifier().glyphPresentation(for: kind, path: path)
        content.image = UIImage(systemName: glyph.systemImageName)
        content.imageProperties.tintColor = switch glyph.tint {
        case .accent: .systemBlue
        case .secondary: .secondaryLabel
        }
        content.imageProperties.maximumSize = CGSize(width: 34, height: 34)
        contentConfiguration = content

        guard entry.kind == .image, loader.supportsArtifacts else { return }
        thumbnailTask = Task { [weak self, loader, path] in
            guard let thumbnail = try? await loader.thumbnail(path: path, maxDimension: 96),
                  !Task.isCancelled,
                  let image = UIImage(data: thumbnail.data),
                  let self,
                  self.representedPath == path else { return }
            var updated = self.defaultContentConfiguration()
            updated.text = entry.name
            updated.secondaryText = ByteCountFormatter.string(
                fromByteCount: entry.size,
                countStyle: .file
            )
            updated.image = image
            updated.imageProperties.maximumSize = CGSize(width: 34, height: 34)
            updated.imageProperties.cornerRadius = 6
            self.contentConfiguration = updated
        }
    }
}
#endif
