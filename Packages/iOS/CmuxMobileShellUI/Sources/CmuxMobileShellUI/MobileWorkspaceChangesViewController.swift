#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileChanges
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation
import UIKit

/// Native workspace-changes flow backed by the existing UIKit list and diff pager.
@MainActor
final class MobileWorkspaceChangesViewController: UIViewController {
    private let store: CMUXMobileShellStore
    private let workspaceID: String
    private let workspaceTitle: String
    private let fontPreference = DiffFontPreference(defaults: .standard)
    private var presentationCache = FileDiffPresentationCache()
    private let inlineActionHost = ChatArtifactInlineActionHost()

    private var branch = ""
    private var base = "HEAD"
    private var totals = ChangesTotals(filesChanged: 0, additions: 0, deletions: 0)
    private var files: [ChangedFileItem] = []
    private var listState: WorkspaceChangesListState = .loading
    private var fontSize: Double
    private var loadTask: Task<Void, Never>?
    private var actionObservationGeneration = 0
    private lazy var listController = makeListController()

    init(store: CMUXMobileShellStore, workspaceID: String, workspaceTitle: String) {
        self.store = store
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        fontSize = fontPreference.pointSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { loadTask?.cancel() }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        addChild(listController)
        listController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(listController.view)
        NSLayoutConstraint.activate([
            listController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listController.view.topAnchor.constraint(equalTo: root.topAnchor),
            listController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        listController.didMove(toParent: self)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("workspace.changes.title", defaultValue: "Changes")
        view.accessibilityIdentifier = "MobileChangesSheet"
        let close = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction(
                title: L10n.string("workspace.changes.close", defaultValue: "Close")
            ) { [weak self] _ in self?.dismiss(animated: true) }
        )
        close.accessibilityIdentifier = "MobileChangesClose"
        navigationItem.leftBarButtonItem = close
        observeInlineActions()
        loadChangedFiles(invalidateCache: true)
    }

    private func makeListController() -> WorkspaceChangesListViewController {
        WorkspaceChangesListViewController(
            branch: branch,
            base: base,
            totals: totals,
            files: files,
            state: listState,
            actions: listActions
        )
    }

    private var listActions: WorkspaceChangesListActions {
        WorkspaceChangesListActions(
            onSelectFile: { [weak self] index in self?.openDiff(at: index) },
            onRefresh: { [weak self] in await self?.loadChangedFilesNow(invalidateCache: true) },
            onRetry: { [weak self] in self?.loadChangedFiles(invalidateCache: true) }
        )
    }

    private var pagerActions: WorkspaceFileDiffPagerActions {
        WorkspaceFileDiffPagerActions(
            onLoad: { [weak self] path, forceRefresh, maxLines in
                guard let self else { throw CancellationError() }
                return try await self.loadDocument(
                    path: path,
                    forceRefresh: forceRefresh,
                    maxLines: maxLines
                )
            },
            onLoadCurrentLines: store.workspaceChangesCurrentFileLinesLoader(workspaceID: workspaceID),
            onPresentationAccess: { [weak self] path in self?.presentationCache.touch(path: path) },
            onPersistFontSize: { [weak self] pointSize in
                self?.fontSize = pointSize
                self?.fontPreference.pointSize = pointSize
            },
            onCopy: { text in UIPasteboard.general.string = text },
            inlinePreview: { [weak self] index, revision in
                self?.inlineArtifactPreview(index: index, revision: revision) ?? UIViewController()
            }
        )
    }

    private func openDiff(at index: Int) {
        guard files.indices.contains(index) else { return }
        let controller = WorkspaceFileDiffPagerViewController(
            files: files,
            initialSelectedIndex: index,
            cachedPresentations: presentationCache.presentations,
            initialFontSize: fontSize,
            actions: pagerActions
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func inlineArtifactPreview(
        index: Int,
        revision: FileDiffPreviewRevision
    ) -> UIViewController {
        guard files.indices.contains(index) else { return UIViewController() }
        let file = files[index]
        let resolvedPath = revision == .base ? (file.oldPath ?? file.path) : file.path
        return ChatArtifactInlineViewController(
            path: resolvedPath,
            loader: store.workspaceChangesArtifactLoader(
                workspaceID: workspaceID,
                path: file.path,
                oldPath: file.oldPath,
                revision: revision
            ),
            actionHost: inlineActionHost
        )
    }

    private func observeInlineActions() {
        actionObservationGeneration += 1
        let generation = actionObservationGeneration
        let descriptor = withObservationTracking {
            inlineActionHost.descriptor
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.actionObservationGeneration == generation else { return }
                self.observeInlineActions()
            }
        }
        navigationController?.topViewController?.navigationItem.rightBarButtonItems = descriptor.map { descriptor in
            descriptor.actions.map { action in
                let item = UIBarButtonItem(
                    image: UIImage(systemName: action.systemImage),
                    primaryAction: UIAction(title: action.localizedTitle) { [weak inlineActionHost] _ in
                        inlineActionHost?.perform(action, descriptorID: descriptor.id)
                    }
                )
                item.isEnabled = !descriptor.isRunning
                return item
            }
        }
    }

    private func loadChangedFiles(invalidateCache: Bool) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadChangedFilesNow(invalidateCache: invalidateCache)
        }
    }

    private func loadChangedFilesNow(invalidateCache: Bool) async {
        if invalidateCache { presentationCache.removeAll() }
        listState = .loading
        renderList()
        do {
            let response = try await store.fetchChangedFiles(workspaceID: workspaceID)
            try Task.checkCancellation()
            branch = response.branch ?? workspaceTitle
            base = response.baseRef ?? "HEAD"
            totals = ChangesTotals(
                filesChanged: response.filesChanged,
                additions: response.additions,
                deletions: response.deletions
            )
            files = response.files.map { file in
                ChangedFileItem(
                    path: file.path,
                    oldPath: file.oldPath,
                    kind: file.status.fileChangeKind,
                    additions: file.additions,
                    deletions: file.deletions,
                    isBinary: file.isBinary,
                    isApproximate: file.isApproximate
                )
            }
            listState = files.isEmpty ? .empty : .loaded(truncated: response.truncated)
        } catch is CancellationError {
            return
        } catch WorkspaceChangesFetchError.notARepository {
            files = []
            totals = ChangesTotals(filesChanged: 0, additions: 0, deletions: 0)
            listState = .notARepository
        } catch {
            listState = .error
        }
        renderList()
    }

    private func renderList() {
        guard isViewLoaded else { return }
        listController.update(
            branch: branch,
            base: base,
            totals: totals,
            files: files,
            state: listState,
            actions: listActions
        )
    }

    private func loadDocument(
        path: String,
        forceRefresh: Bool,
        maxLines: Int?
    ) async throws -> FileDiffPresentation {
        if maxLines == nil,
           !forceRefresh,
           let cached = presentationCache.presentation(forPath: path) {
            return cached
        }
        let response = try await store.fetchFileDiff(
            workspaceID: workspaceID,
            path: path,
            maxLines: maxLines
        )
        let presentation = await UnifiedDiffParser().parsePresentationOffMain(
            response.unifiedDiff,
            truncated: response.truncated,
            isBinary: response.isBinary,
            totalLineCount: response.diffTotalLines,
            contentFingerprint: response.contentFingerprint,
            fileKind: response.status.fileChangeKind
        )
        try Task.checkCancellation()
        if maxLines == nil { presentationCache.insert(presentation, forPath: path) }
        return presentation
    }
}
#endif
