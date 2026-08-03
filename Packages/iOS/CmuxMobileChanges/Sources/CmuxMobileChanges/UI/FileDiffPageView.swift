internal import Foundation

#if canImport(UIKit)
public import UIKit

/// One independently loading native diff page.
@MainActor
public final class FileDiffPageViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate,
    UIGestureRecognizerDelegate
{
    let fileIndex: Int
    let file: ChangedFileItem
    var fontSize: Double
    let onFontSizeChanged: @MainActor @Sendable (Double) -> Void
    let onScrollRowIDChanged: @MainActor @Sendable (String?) -> Void
    let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    let onLoad: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation
    let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile
    let onCopy: @MainActor @Sendable (String) -> Void
    let inlinePreview: (@MainActor @Sendable (Int, FileDiffPreviewRevision) -> UIViewController)?

    var loadState: FileDiffLoadState
    var scrollRowID: String?
    var previewRevision: FileDiffPreviewRevision
    var expansionState = DiffExpansionState()
    var currentFileLines: [String]?
    var pendingExpansionGapID: Int?
    var pendingExpansionDirection: DiffExpansionDirection?
    var failedExpansionGapID: Int?
    var failedExpansionDirection: DiffExpansionDirection?
    var expansionContentTooLarge = false
    var expansionTask: Task<Void, Never>?
    var continuationTask: Task<Void, Never>?
    var lineBudget = FileDiffContinuation.defaultLineBudget
    var continuationLoadState = FileDiffContinuationLoadState.idle
    var reachedTransportCeiling = false
    var requestGeneration = FileDiffRequestGeneration()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var pageLoadTask: Task<Void, Never>?
    private var binaryController: FileDiffBinaryViewController?
    private var theme = ChangesTheme(appearance: .light)
    private var magnificationStart: Double?
    private var didRestoreScrollPosition = false

    public init(
        fileIndex: Int,
        file: ChangedFileItem,
        initialPresentation: FileDiffPresentation?,
        initialScrollRowID: String? = nil,
        fontSize: Double,
        onFontSizeChanged: @escaping @MainActor @Sendable (Double) -> Void,
        onScrollRowIDChanged: @escaping @MainActor @Sendable (String?) -> Void = { _ in },
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onLoad: @escaping @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (Int, FileDiffPreviewRevision) -> UIViewController)? = nil
    ) {
        self.fileIndex = fileIndex
        self.file = file
        self.fontSize = fontSize
        self.onFontSizeChanged = onFontSizeChanged
        self.onScrollRowIDChanged = onScrollRowIDChanged
        self.onPersistFontSize = onPersistFontSize
        self.onLoad = onLoad
        self.onLoadCurrentLines = onLoadCurrentLines
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
        loadState = initialPresentation.map(FileDiffLoadState.loaded) ?? .loading
        scrollRowID = initialScrollRowID
        previewRevision = FileDiffPreviewPolicy(kind: file.kind).defaultRevision
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "MobileChangesDiffPage-\(file.path)"
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28
        tableView.keyboardDismissMode = .onDrag
        tableView.register(DiffLineCell.self, forCellReuseIdentifier: DiffLineCell.reuseIdentifier)
        tableView.register(DiffExpanderCell.self, forCellReuseIdentifier: DiffExpanderCell.reuseIdentifier)
        tableView.register(
            FileDiffContinuationCell.self,
            forCellReuseIdentifier: FileDiffContinuationCell.reuseIdentifier
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Placeholder")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.load(forceRefresh: true)
                refresh.endRefreshing()
            }
        }, for: .valueChanged)
        tableView.refreshControl = refresh

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        tableView.addGestureRecognizer(pinch)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: FileDiffPageViewController, _) in
            controller.render()
        }
        render()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard case .loading = loadState, pageLoadTask == nil else { return }
        pageLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load(forceRefresh: false)
            self.pageLoadTask = nil
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        publishScrollPosition()
        pageLoadTask?.cancel()
        pageLoadTask = nil
        cancelPageTasks()
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch loadState {
        case .loading:
            return 24
        case .failed:
            return 0
        case .loaded(let presentation):
            guard !presentation.document.isBinary else { return 0 }
            return presentation.rows.count + (continuation(for: presentation)?.shouldShowFooter == true ? 1 : 0)
        }
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch loadState {
        case .loading:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Placeholder", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = "let placeholder\(indexPath.row) = true"
            content.textProperties.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            content.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .failed:
            return UITableViewCell()
        case .loaded(let presentation):
            if indexPath.row == presentation.rows.count,
               let continuation = continuation(for: presentation) {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: FileDiffContinuationCell.reuseIdentifier,
                    for: indexPath
                ) as! FileDiffContinuationCell
                cell.configure(
                    continuation: continuation,
                    state: continuationLoadState,
                    onShowMore: { [weak self] in self?.showMore() }
                )
                return cell
            }
            let row = presentation.rows[indexPath.row]
            switch row.content {
            case .line(let line, _):
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: DiffLineCell.reuseIdentifier,
                    for: indexPath
                ) as! DiffLineCell
                let gutterWidth = DiffGutterLayout(
                    maximumLineNumber: presentation.maximumLineNumber
                ).measuredWidth(fontSize: fontSize)
                cell.configure(line: line, gutterWidth: gutterWidth, fontSize: fontSize, theme: theme)
                if row.leadingHunkGap {
                    cell.contentView.directionalLayoutMargins.top = theme.hunkSpacing
                }
                return cell
            case .expander(let snapshot):
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: DiffExpanderCell.reuseIdentifier,
                    for: indexPath
                ) as! DiffExpanderCell
                cell.configure(
                    snapshot: snapshot,
                    status: expansionRowStatus(for: snapshot),
                    interactionDisabled: pendingExpansionGapID != nil,
                    theme: theme,
                    onExpand: { [weak self] snapshot, direction in
                        self?.expand(snapshot, direction: direction)
                    }
                )
                return cell
            }
        }
    }

    public func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .loaded(let presentation) = loadState,
              presentation.rows.indices.contains(indexPath.row),
              case .line(let line, let hunkCopyText) = presentation.rows[indexPath.row].content,
              line.kind != .noNewlineMarker else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var actions = [UIAction(
                title: String(localized: "changes.copy.line", defaultValue: "Copy Line", bundle: .module),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in self?.onCopy(line.text) }]
            if !hunkCopyText.isEmpty {
                actions.append(UIAction(
                    title: String(localized: "changes.copy.hunk", defaultValue: "Copy Hunk", bundle: .module),
                    image: UIImage(systemName: "doc.on.doc.fill")
                ) { _ in self?.onCopy(hunkCopyText) })
            }
            return UIMenu(children: actions)
        })
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { publishScrollPosition() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        publishScrollPosition()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            magnificationStart = fontSize
        case .changed:
            let start = magnificationStart ?? fontSize
            fontSize = clamped(start * recognizer.scale)
            onFontSizeChanged(fontSize)
            tableView.reloadData()
        case .ended:
            let start = magnificationStart ?? fontSize
            fontSize = clamped(start * recognizer.scale)
            magnificationStart = nil
            onFontSizeChanged(fontSize)
            onPersistFontSize(fontSize)
            tableView.reloadData()
        case .cancelled, .failed:
            magnificationStart = nil
        default:
            break
        }
    }

    func render() {
        guard isViewLoaded else { return }
        theme = ChangesTheme(traitCollection: traitCollection)
        configureFailureView()
        configureBinaryView()
        tableView.reloadData()
        restoreScrollPositionIfNeeded()
    }

    @MainActor
    func load(forceRefresh: Bool) async {
        cancelContinuationTask()
        let generation = requestGeneration.begin()
        resetExpansion()
        loadState = .loading
        continuationLoadState = .idle
        render()
        do {
            let maxLines = lineBudget == FileDiffContinuation.defaultLineBudget ? nil : lineBudget
            let presentation = try await onLoad(file.path, forceRefresh, maxLines)
            guard !Task.isCancelled, requestGeneration.isCurrent(generation) else { return }
            reachedTransportCeiling = false
            loadState = .loaded(presentation)
        } catch is CancellationError {
            guard requestGeneration.isCurrent(generation),
                  RecoverableCancellationErrorPolicy().shouldPublishFailure(
                      taskIsCancelled: Task.isCancelled
                  ) else { return }
            loadState = .failed
        } catch {
            guard !Task.isCancelled, requestGeneration.isCurrent(generation) else { return }
            loadState = .failed
        }
        render()
    }

    @MainActor
    func showMore() {
        guard case .loaded(let presentation) = loadState,
              continuationLoadState != .loading else { return }
        let continuation = FileDiffContinuation(
            lineBudget: lineBudget,
            document: presentation.document,
            reachedTransportCeiling: reachedTransportCeiling
        )
        guard continuation.canShowMore else { return }
        let nextLineBudget = continuation.nextLineBudget
        cancelContinuationTask()
        let generation = requestGeneration.begin()
        resetExpansion()
        continuationLoadState = .loading
        render()
        continuationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let expanded = try await self.onLoad(self.file.path, false, nextLineBudget)
                guard !Task.isCancelled, self.requestGeneration.isCurrent(generation) else { return }
                self.reachedTransportCeiling = continuation.reachedTransportCeiling(
                    afterLoading: expanded.document,
                    requestedLineBudget: nextLineBudget
                )
                self.lineBudget = nextLineBudget
                self.continuationLoadState = .idle
                self.loadState = .loaded(expanded)
            } catch is CancellationError {
                guard self.requestGeneration.isCurrent(generation),
                      RecoverableCancellationErrorPolicy().shouldPublishFailure(
                          taskIsCancelled: Task.isCancelled
                      ) else { return }
                self.continuationLoadState = .failed
            } catch {
                guard !Task.isCancelled, self.requestGeneration.isCurrent(generation) else { return }
                self.continuationLoadState = .failed
            }
            self.continuationTask = nil
            self.render()
        }
    }

    private func continuation(for presentation: FileDiffPresentation) -> FileDiffContinuation? {
        let continuation = FileDiffContinuation(
            lineBudget: lineBudget,
            document: presentation.document,
            reachedTransportCeiling: reachedTransportCeiling
        )
        return continuation.shouldShowFooter ? continuation : nil
    }

    private func configureFailureView() {
        guard case .failed = loadState else {
            tableView.backgroundView = nil
            return
        }
        tableView.backgroundView = ChangesUnavailableView(
            systemImage: "exclamationmark.triangle",
            title: String(localized: "changes.diff.error.title", defaultValue: "Couldn't load diff", bundle: .module),
            message: String(
                localized: "changes.diff.error.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ),
            buttonTitle: String(localized: "changes.retry", defaultValue: "Retry", bundle: .module),
            action: { [weak self] in
                Task { @MainActor [weak self] in await self?.load(forceRefresh: true) }
            }
        )
    }

    private func configureBinaryView() {
        guard case .loaded(let presentation) = loadState, presentation.document.isBinary else {
            if let binaryController {
                binaryController.willMove(toParent: nil)
                binaryController.view.removeFromSuperview()
                binaryController.removeFromParent()
                self.binaryController = nil
            }
            tableView.isHidden = false
            return
        }
        guard binaryController == nil else { return }
        tableView.isHidden = true
        let controller = FileDiffBinaryViewController(
            fileIndex: fileIndex,
            file: file,
            previewRevision: previewRevision,
            inlinePreview: inlinePreview
        )
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        binaryController = controller
    }

    private func restoreScrollPositionIfNeeded() {
        guard !didRestoreScrollPosition,
              let scrollRowID,
              case .loaded(let presentation) = loadState,
              let index = presentation.rows.firstIndex(where: { $0.id == scrollRowID }) else { return }
        didRestoreScrollPosition = true
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
    }

    private func publishScrollPosition() {
        guard case .loaded(let presentation) = loadState,
              let first = tableView.indexPathsForVisibleRows?.min(),
              presentation.rows.indices.contains(first.row) else { return }
        scrollRowID = presentation.rows[first.row].id
        onScrollRowIDChanged(scrollRowID)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, DiffFontPreference.minimumPointSize), DiffFontPreference.maximumPointSize)
    }
}
#endif
