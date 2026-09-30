import CmuxFileTree
import Foundation

/// Per-workspace expansion, selection and scroll persistence.
@MainActor
extension FileExplorerStore {
    /// The persistence key: one workspace's view of one root on one host.
    var viewStateScope: String? {
        guard let workspaceRootIdentity, !rootPath.isEmpty, let provider else { return nil }
        let host: String
        switch provider {
        case is LocalFileExplorerProvider:
            host = "local"
        case let cloud as CloudVMFileExplorerProvider:
            host = "cloud:\(cloud.vmID)"
        case let remote as any RemoteFileExplorerProvider:
            host = remote.remoteIdentity
        default:
            host = String(describing: type(of: provider))
        }
        return "\(workspaceRootIdentity.uuidString)|\(host)|\(rootPath)"
    }

    /// The current view state, relative to the root.
    func currentViewState() -> FileTreeViewState {
        let root = rootPath
        let expanded = expandedPaths.compactMap { FileTreeViewState.relativePath($0, root: root) }
            .filter { !$0.isEmpty }
            .sorted()
        let selected = selectedPaths.compactMap { FileTreeViewState.relativePath($0, root: root) }.sorted()
        let anchor = scrollAnchorFromObservers ?? pendingScrollAnchor
        return FileTreeViewState(
            expandedPaths: expanded,
            selectedPaths: selected,
            anchorPath: selectedPath.flatMap { FileTreeViewState.relativePath($0, root: root) },
            topVisiblePath: anchor.flatMap { FileTreeViewState.relativePath($0.path, root: root) },
            topVisibleOffset: anchor?.offset ?? 0
        )
    }

    /// Saves at the end of this main-actor turn so a burst of expansions or
    /// selection changes writes once.
    func scheduleViewStateSave() {
        guard viewStateRepository != nil, viewStateSaveTask == nil else { return }
        viewStateSaveTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.viewStateSaveTask = nil
            self.saveViewStateNow()
        }
    }

    /// Captures and saves the state immediately; called before the root or
    /// workspace changes so the outgoing scroll position is kept.
    func saveViewStateNow() {
        guard let repository = viewStateRepository, let scope = viewStateScope, treeSession != nil else { return }
        let state = currentViewState()
        Task { await repository.save(state, for: scope) }
    }

    /// Restores a saved state for a session that just started. In-memory
    /// state (a reload of the same root) wins over disk.
    func restorePersistedViewState(for session: FileExplorerTreeSession) {
        guard let repository = viewStateRepository, let scope = viewStateScope,
              expandedPaths.isEmpty, selectedPaths.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let state = await repository.state(for: scope) else { return }
            guard let self, self.isCurrent(session.id), self.viewStateScope == scope else { return }
            self.applyRestoredViewState(state, root: session.rootPath)
        }
    }

    private func applyRestoredViewState(_ state: FileTreeViewState, root: String) {
        let restoredExpanded = state.expandedPaths.map { FileTreeViewState.absolutePath($0, root: root) }
        expandedPaths.formUnion(restoredExpanded)
        if selectedPaths.isEmpty || (selectedPaths.count == 1 && selectedPath == rootNodes.first?.path) {
            let selected = state.selectedPaths.map { FileTreeViewState.absolutePath($0, root: root) }
            if !selected.isEmpty {
                selectedPaths = Set(selected)
                selectedPath = state.anchorPath.map { FileTreeViewState.absolutePath($0, root: root) } ?? selected.first
            }
        }
        if let top = state.topVisiblePath {
            pendingScrollAnchor = (FileTreeViewState.absolutePath(top, root: root), state.topVisibleOffset)
        }
        // The root may already be listed; expand what is loaded and list the rest.
        var toExpand: [FileExplorerNode] = []
        for node in rootNodes where node.isDirectory && expandedPaths.contains(node.path) {
            toExpand.append(node)
        }
        if !toExpand.isEmpty {
            let loads = toExpand.filter { $0.children == nil && !loadingPaths.contains($0.path) }.map(\.path)
            if !loads.isEmpty { requestLoad(loads) }
            notifyObservers { $0.fileExplorerTree(self, expand: toExpand) }
        }
        notifyObservers { $0.fileExplorerTreeDidChangeSelection(self, scrollToAnchor: false) }
        if let anchor = pendingScrollAnchor, let node = nodesByPath[anchor.path], isVisible(node) {
            pendingScrollAnchor = nil
            notifyObservers { $0.fileExplorerTree(self, restoreScrollTo: node, offset: anchor.offset) }
        }
    }
}
