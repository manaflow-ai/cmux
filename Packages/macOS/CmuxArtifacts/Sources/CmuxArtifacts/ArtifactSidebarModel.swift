public import Foundation
public import Observation

/// Main-actor projection of the artifact repository for sidebar rendering.
///
/// The filesystem remains authoritative. This model owns only view lifecycle,
/// expansion, and search state, and emits immutable row snapshots for SwiftUI.
@MainActor
@Observable
public final class ArtifactSidebarModel {
    /// Current loading phase.
    public private(set) var phase: ArtifactSidebarPhase = .unavailable
    /// Flattened immutable rows rendered by the sidebar.
    public private(set) var rows: [ArtifactSidebarRowSnapshot] = []
    /// Current filename/content search query.
    public private(set) var query = ""
    /// Most recent recoverable action failure.
    public private(set) var actionFailure: ArtifactSidebarFailure?
    /// Resolved project root for copy/reference and header presentation.
    public private(set) var projectRoot: URL?

    private let store: any ArtifactStoring
    private let captureService: any ArtifactCapturing
    private let searchDebounce: Duration
    private var workspace: ArtifactSidebarWorkspace?
    private var nodes: [ArtifactNode] = []
    private var expandedPaths: Set<String> = []
    private var hasInitializedExpansion = false
    private var watcherTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var bindingRequestRevision: UInt64 = 0
    private var bindingRevision: UInt64 = 0
    private var latestWorkspaceTitle: (id: String, title: String?)?

    /// Creates a sidebar model with injected filesystem and capture seams.
    ///
    /// - Parameters:
    ///   - store: Authoritative filesystem repository.
    ///   - captureService: Shared validated manual-capture service.
    ///   - searchDebounce: Cancellable delay used to coalesce typing into searches.
    public init(
        store: any ArtifactStoring,
        captureService: any ArtifactCapturing,
        searchDebounce: Duration = .milliseconds(150)
    ) {
        self.store = store
        self.captureService = captureService
        self.searchDebounce = searchDebounce
    }

    deinit {
        // This model is created and released by SwiftUI on the main actor.
        // `isolated deinit` is unavailable in Xcode 16.4.
        MainActor.assumeIsolated {
            watcherTask?.cancel()
            searchTask?.cancel()
            actionTask?.cancel()
        }
    }

    /// Binds the model to a selected local workspace and loads its initial tree.
    ///
    /// Passing `nil` clears the tree and stops filesystem observation.
    ///
    /// - Parameter workspace: Selected local workspace, or `nil` when unavailable.
    public func bind(workspace: ArtifactSidebarWorkspace?) async {
        guard self.workspace != workspace else { return }
        bindingRequestRevision &+= 1
        let requestRevision = bindingRequestRevision
        guard var workspace else {
            stop()
            return
        }
        if latestWorkspaceTitle?.id == workspace.id {
            workspace = ArtifactSidebarWorkspace(
                id: workspace.id,
                title: latestWorkspaceTitle?.title,
                workingDirectory: workspace.workingDirectory
            )
        }
        let root = await store.locateProjectRoot(startingAt: workspace.workingDirectory)
        guard requestRevision == bindingRequestRevision, !Task.isCancelled else { return }
        if self.workspace?.id == workspace.id, projectRoot == root {
            self.workspace = workspace
            return
        }

        bindingRevision &+= 1
        let revision = bindingRevision
        watcherTask?.cancel()
        watcherTask = nil
        searchTask?.cancel()
        searchTask = nil
        actionTask?.cancel()
        actionTask = nil
        self.workspace = workspace
        projectRoot = nil
        nodes = []
        rows = []
        expandedPaths = []
        hasInitializedExpansion = false
        actionFailure = nil

        phase = .loading
        projectRoot = root
        await reload(projectRoot: root, revision: revision)
        guard revision == bindingRevision, !Task.isCancelled else { return }
        startWatching(projectRoot: root, revision: revision)
    }

    /// Reloads the current filesystem tree immediately.
    public func refresh() async {
        guard let projectRoot else { return }
        await reload(projectRoot: projectRoot, revision: bindingRevision)
    }

    /// Starts a refresh owned by this model and cancels any obsolete sidebar action.
    public func requestRefresh() {
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    /// Stops long-lived observation tasks when the owning UI is torn down.
    public func stop() {
        bindingRequestRevision &+= 1
        bindingRevision &+= 1
        watcherTask?.cancel()
        watcherTask = nil
        searchTask?.cancel()
        searchTask = nil
        actionTask?.cancel()
        actionTask = nil
        workspace = nil
        projectRoot = nil
        nodes = []
        rows = []
        expandedPaths = []
        hasInitializedExpansion = false
        actionFailure = nil
        phase = .unavailable
    }

    /// Updates cosmetic workspace metadata without rebinding the filesystem watcher.
    public func updateWorkspaceTitle(workspaceID: String, title: String?) {
        latestWorkspaceTitle = (workspaceID, title)
        guard let workspace, workspace.id == workspaceID else { return }
        self.workspace = ArtifactSidebarWorkspace(
            id: workspace.id,
            title: title,
            workingDirectory: workspace.workingDirectory
        )
    }

    /// Updates filename/content search and schedules a repository query.
    ///
    /// - Parameter query: User-entered query.
    public func setQuery(_ query: String) {
        guard self.query != query else { return }
        self.query = query
        scheduleSearch()
    }

    /// Expands or collapses a directory row.
    ///
    /// - Parameter relativePath: Directory path relative to the artifact root.
    public func toggleExpansion(relativePath: String) {
        if expandedPaths.contains(relativePath) {
            expandedPaths.remove(relativePath)
        } else {
            expandedPaths.insert(relativePath)
        }
        rebuildTreeRows()
    }

    /// Adds user-selected files through the shared validated capture service.
    ///
    /// - Parameter urls: Existing local regular files selected by the user.
    public func addFiles(_ urls: [URL]) async {
        guard let projectRoot, let workspace else { return }
        actionFailure = nil
        let context = ArtifactCaptureContext(
            projectRoot: projectRoot,
            workspaceID: workspace.id,
            workspaceTitle: workspace.title
        )
        do {
            for url in urls {
                try Task.checkCancellation()
                _ = try await captureService.add(
                    sourceURL: url,
                    context: context,
                    capturedAt: .now
                )
            }
            try Task.checkCancellation()
            await reload(projectRoot: projectRoot, revision: bindingRevision)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            actionFailure = .add
        }
    }

    /// Starts manual capture owned by this model and cancels any obsolete sidebar action.
    ///
    /// - Parameter urls: Existing local regular files selected by the user.
    public func requestAddFiles(_ urls: [URL]) {
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            await self?.addFiles(urls)
        }
    }

    /// Clears the current recoverable action failure after presentation.
    public func clearActionFailure() {
        actionFailure = nil
    }

    private func startWatching(projectRoot: URL, revision: UInt64) {
        let store = self.store
        watcherTask = Task { [weak self] in
            let changes = await store.changes(projectRoot: projectRoot)
            for await _ in changes {
                guard !Task.isCancelled else { break }
                await self?.reload(projectRoot: projectRoot, revision: revision)
            }
        }
    }

    private func reload(projectRoot: URL, revision: UInt64) async {
        do {
            let snapshot = try await store.snapshot(projectRoot: projectRoot)
            guard revision == bindingRevision, !Task.isCancelled else { return }
            nodes = snapshot.nodes
            if !hasInitializedExpansion {
                expandedPaths = defaultExpandedPaths(nodes: snapshot.nodes)
                hasInitializedExpansion = true
            }
            phase = .loaded
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rebuildTreeRows()
            } else {
                scheduleSearch()
            }
        } catch {
            guard revision == bindingRevision, !Task.isCancelled else { return }
            phase = .failed
            rows = []
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            rebuildTreeRows()
            return
        }
        guard let projectRoot else {
            rows = []
            return
        }
        let revision = bindingRevision
        let store = self.store
        let searchDebounce = self.searchDebounce
        searchTask = Task { [weak self] in
            do {
                // This bounded, injected delay is the intended search debounce and is cancelled on new input.
                try await Task.sleep(for: searchDebounce)
                let results = try await store.search(projectRoot: projectRoot, query: trimmedQuery)
                guard !Task.isCancelled else { return }
                self?.applySearchResults(results, revision: revision, query: trimmedQuery)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.applySearchFailure(revision: revision, query: trimmedQuery)
            }
        }
    }

    private func applySearchResults(
        _ results: [ArtifactSearchResult],
        revision: UInt64,
        query searchedQuery: String
    ) {
        guard revision == bindingRevision,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery else { return }
        rows = results.map { result in
            row(node: result.node, depth: 0, matchedContent: result.matchedContent, snippet: result.snippet)
        }
    }

    private func applySearchFailure(revision: UInt64, query searchedQuery: String) {
        guard revision == bindingRevision,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == searchedQuery else { return }
        rows = []
        actionFailure = .search
    }

    private func rebuildTreeRows() {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rows = flattened(nodes: nodes, depth: 0)
    }

    private func flattened(nodes: [ArtifactNode], depth: Int) -> [ArtifactSidebarRowSnapshot] {
        nodes.flatMap { node in
            var result = [row(node: node, depth: depth)]
            if node.isDirectory, expandedPaths.contains(node.relativePath) {
                result.append(contentsOf: flattened(nodes: node.children, depth: depth + 1))
            }
            return result
        }
    }

    private func row(
        node: ArtifactNode,
        depth: Int,
        matchedContent: Bool = false,
        snippet: String? = nil
    ) -> ArtifactSidebarRowSnapshot {
        ArtifactSidebarRowSnapshot(
            id: node.id,
            name: node.name,
            relativePath: node.relativePath,
            fileURL: URL(fileURLWithPath: node.absolutePath, isDirectory: node.isDirectory),
            depth: depth,
            isDirectory: node.isDirectory,
            isExpanded: node.isDirectory && expandedPaths.contains(node.relativePath),
            fileKind: node.fileKind,
            matchedContent: matchedContent,
            snippet: snippet
        )
    }

    private func defaultExpandedPaths(nodes: [ArtifactNode]) -> Set<String> {
        var paths: Set<String> = []
        for node in nodes where node.isDirectory {
            paths.insert(node.relativePath)
            for child in node.children where child.isDirectory {
                paths.insert(child.relativePath)
            }
        }
        return paths
    }
}
