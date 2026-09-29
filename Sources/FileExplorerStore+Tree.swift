import CmuxFileTree
import Foundation

/// One engine bound to one root on one provider. Replaced, never mutated.
struct FileExplorerTreeSession {
    let id: UInt64
    let engine: FileTreeEngine
    let rootPath: String
    let provider: FileExplorerProvider
}

/// The upper bound on folders an Option-click expansion opens, so expanding
/// a project root cannot walk all of `node_modules`.
private let recursiveExpansionDirectoryLimit = 500

@MainActor
extension FileExplorerStore {
    // MARK: - Observers

    func addTreeObserver(_ observer: any FileExplorerTreeObserving) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
        observers.append(WeakFileExplorerTreeObserver(observer: observer))
    }

    func removeTreeObserver(_ observer: any FileExplorerTreeObserving) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
    }

    func notifyObservers(_ body: (any FileExplorerTreeObserving) -> Void) {
        for box in observers {
            if let observer = box.observer { body(observer) }
        }
    }

    /// The observer that can report scroll position, if one is attached.
    var scrollAnchorFromObservers: (path: String, offset: Double)? {
        for box in observers {
            if let anchor = box.observer?.fileExplorerTreeScrollAnchor(self) { return anchor }
        }
        return nil
    }

    // MARK: - Session lifecycle

    /// Drops every row and re-lists the root plus every expanded folder.
    /// Expansion and selection survive; the view reloads once.
    func reload(restoringViewState: Bool = false) {
        tearDownTree()
        startTree(restoringViewState: restoringViewState)
    }

    func tearDownTree() {
        loadFlushTask?.cancel(); loadFlushTask = nil
        refreshTask?.cancel(); refreshTask = nil
        watchTask?.cancel(); watchTask = nil
        prefetchScheduler.cancel()
        treeSession = nil
        rootNodes = []
        nodesByPath = [:]
        loadingPaths = []
        pendingLoadPaths = []
        pendingSilentLoadPaths = []
        pendingRefreshPaths = []
        deferredUpdates = []
        pendingDescendIntoFirstChildPath = nil
        pendingRenamePath = nil
        recursiveExpansionBudget = 0
        recursiveExpansionRoots = []
        if isRootLoading { isRootLoading = false }
        notifyObservers { $0.fileExplorerTreeDidReset(self) }
    }

    private func startTree(restoringViewState: Bool) {
        guard !rootPath.isEmpty, let provider, provider.isAvailable else { return }
        treeSessionCounter &+= 1
        let session = FileExplorerTreeSession(
            id: treeSessionCounter,
            engine: FileTreeEngine(provider: provider, sortOrder: sortOrder, showsHiddenFiles: showHiddenFiles),
            rootPath: rootPath,
            provider: provider
        )
        treeSession = session
        contentRevision &+= 1
        isRootLoading = true
        requestLoad([rootPath])
        startWatching(session)
        if restoringViewState {
            restorePersistedViewState(for: session)
        }
    }

    func isCurrent(_ sessionID: UInt64) -> Bool {
        treeSession?.id == sessionID
    }

    // MARK: - Loading

    /// Queues directory listings. Requests made in the same main-actor turn
    /// (restoring many expanded folders, a recursive expansion level) go to
    /// the provider as one batch, which is one round trip over SSH.
    /// - Parameter silent: Prefetches do not show a spinner.
    func requestLoad(_ paths: [String], silent: Bool = false) {
        guard treeSession != nil else { return }
        var refreshed: [FileExplorerNode] = []
        for path in paths {
            if !pendingLoadPaths.contains(path) { pendingLoadPaths.append(path) }
            if silent {
                pendingSilentLoadPaths.insert(path)
                continue
            }
            pendingSilentLoadPaths.remove(path)
            loadingPaths.insert(path)
            if let node = nodesByPath[path], !node.isLoading {
                node.isLoading = true
                refreshed.append(node)
            }
        }
        if !refreshed.isEmpty {
            notifyObservers { $0.fileExplorerTree(self, didRefreshRowsFor: refreshed) }
        }
        scheduleLoadFlush()
    }

    private func scheduleLoadFlush() {
        guard loadFlushTask == nil, let session = treeSession else { return }
        loadFlushTask = Task { @MainActor [weak self] in
            // Let every expansion requested in this turn join the batch.
            await Task.yield()
            guard let self, self.isCurrent(session.id) else { return }
            self.loadFlushTask = nil
            let paths = self.pendingLoadPaths
            self.pendingLoadPaths = []
            self.pendingSilentLoadPaths = []
            guard !paths.isEmpty else { return }
            let updates = await session.engine.load(paths)
            guard self.isCurrent(session.id) else { return }
            self.apply(updates, sessionID: session.id)
        }
    }

    /// Re-lists the root and every visibly expanded folder. Remote providers
    /// have no change stream, so the panel calls this when it regains focus
    /// and on Refresh.
    func refreshVisibleDirectories() {
        guard treeSession != nil else { return }
        var paths: Set<String> = [rootPath]
        for path in expandedPaths {
            if let node = nodesByPath[path], node.children != nil, isVisiblyExpanded(node) {
                paths.insert(path)
            }
        }
        pendingRefreshPaths.formUnion(paths)
        scheduleRefresh()
    }

    private func startWatching(_ session: FileExplorerTreeSession) {
        guard let stream = session.provider.changes(under: session.rootPath) else { return }
        watchTask = Task { @MainActor [weak self] in
            for await batch in stream {
                guard let self, self.isCurrent(session.id) else { return }
                let affected = await session.engine.affectedDirectories(for: batch)
                guard self.isCurrent(session.id) else { return }
                self.handleChangedDirectories(affected)
            }
        }
    }

    /// Visible folders re-list now; collapsed ones re-list when next expanded.
    func handleChangedDirectories(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for path in paths {
            if path == rootPath {
                pendingRefreshPaths.insert(path)
            } else if let node = nodesByPath[path] {
                if isVisiblyExpanded(node) {
                    pendingRefreshPaths.insert(path)
                } else {
                    node.isStale = true
                }
            }
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard refreshTask == nil, !pendingRefreshPaths.isEmpty, let session = treeSession else { return }
        refreshTask = Task { @MainActor [weak self] in
            // One refresh runs at a time; changes that land meanwhile coalesce
            // into the next pass, so a build's event storm costs a few passes.
            while let self, self.isCurrent(session.id), !self.pendingRefreshPaths.isEmpty {
                let paths = self.pendingRefreshPaths.sorted()
                self.pendingRefreshPaths = []
                let updates = await session.engine.load(paths)
                guard self.isCurrent(session.id) else { return }
                let changed = updates.contains { update in
                    if case .loaded(_, let diff, _) = update.outcome { return !diff.isEmpty }
                    return true
                }
                self.apply(updates, sessionID: session.id)
                if changed {
                    self.contentRevision &+= 1
                    self.refreshGitStatus()
                }
            }
            self?.refreshTask = nil
        }
    }

    // MARK: - Presentation

    func applyPresentationChange() {
        guard let session = treeSession else { return }
        let sortOrder = self.sortOrder
        let showHidden = self.showHiddenFiles
        Task { @MainActor [weak self] in
            let updates = await session.engine.setPresentation(sortOrder: sortOrder, showsHiddenFiles: showHidden)
            guard let self, self.isCurrent(session.id) else { return }
            self.apply(updates, sessionID: session.id)
        }
    }

    // MARK: - Context-menu freeze

    /// Holds incoming updates while AppKit draws a context-menu highlight over
    /// a row index; changing rows under it crashes (#12914).
    func freezeTreeUpdates() {
        frozenUpdateDepth += 1
    }

    /// Applies updates that arrived while frozen, in order.
    func thawTreeUpdates() {
        guard frozenUpdateDepth > 0 else { return }
        frozenUpdateDepth -= 1
        guard frozenUpdateDepth == 0, !deferredUpdates.isEmpty else { return }
        let pending = deferredUpdates
        deferredUpdates = []
        for item in pending where isCurrent(item.sessionID) {
            apply(item.updates, sessionID: item.sessionID)
        }
    }

    var isTreeFrozen: Bool { frozenUpdateDepth > 0 }

    // MARK: - Applying updates

    func apply(_ updates: [FileTreeDirectoryUpdate], sessionID: UInt64) {
        guard !updates.isEmpty, isCurrent(sessionID) else { return }
        if frozenUpdateDepth > 0 {
            deferredUpdates.append((sessionID, updates))
            return
        }
        var refreshedRows: [FileExplorerNode] = []
        var toExpand: [FileExplorerNode] = []
        var selectionTouched = false
        var recursiveLoads: [String] = []
        for update in updates {
            let isRoot = update.path == rootPath
            let parent = isRoot ? nil : nodesByPath[update.path]
            guard isRoot || parent != nil else { continue }
            if !pendingLoadPaths.contains(update.path) {
                loadingPaths.remove(update.path)
            }
            switch update.outcome {
            case .failed(let message):
                if let parent {
                    parent.isLoading = false
                    parent.error = message
                    refreshedRows.append(parent)
                } else {
                    if isRootLoading { isRootLoading = false }
                    setRootStatusMessage(message)
                }
            case .loaded(let entries, let diff, let omittedCount):
                if let parent {
                    let hadPresentationChange = parent.isLoading || parent.error != nil ||
                        parent.omittedCount != omittedCount
                    parent.isLoading = false
                    parent.error = nil
                    parent.isStale = false
                    parent.omittedCount = omittedCount
                    if hadPresentationChange { refreshedRows.append(parent) }
                } else {
                    if isRootLoading { isRootLoading = false }
                    setRootStatusMessage(nil)
                }
                let result = applyChildren(entries, diff: diff, to: parent)
                if !diff.isEmpty {
                    notifyObservers {
                        $0.fileExplorerTree(self, didUpdateChildrenOf: parent, diff: diff, updatedNodes: result.updated)
                    }
                }
                selectionTouched = selectionTouched || result.revealedSelection
                if parent == nil || isVisiblyExpanded(parent!) {
                    let candidates = update.isInitialLoad ? (parent?.children ?? rootNodes) : result.inserted
                    for child in candidates where child.isDirectory && expandedPaths.contains(child.path) {
                        toExpand.append(child)
                    }
                    if let parent, isUnderRecursiveExpansion(parent) {
                        for child in parent.children ?? [] where child.isDirectory && !child.isSymbolicLink {
                            guard recursiveExpansionBudget > 0 else { break }
                            if !expandedPaths.contains(child.path) {
                                recursiveExpansionBudget -= 1
                                expandedPaths.insert(child.path)
                                toExpand.append(child)
                                if child.children == nil { recursiveLoads.append(child.path) }
                            }
                        }
                    }
                }
                if let pending = pendingDescendIntoFirstChildPath, pending == update.path {
                    let target = (parent?.children ?? rootNodes).first?.path ?? update.path
                    selectedPath = target
                    selectedPaths = [target]
                    pendingDescendIntoFirstChildPath = nil
                    selectionTouched = true
                }
                if isRoot, update.isInitialLoad, selectedPath == nil, let first = rootNodes.first {
                    selectedPath = first.path
                    selectedPaths = [first.path]
                    selectionTouched = true
                }
            }
        }
        if !refreshedRows.isEmpty {
            notifyObservers { $0.fileExplorerTree(self, didRefreshRowsFor: refreshedRows) }
        }
        if !toExpand.isEmpty {
            // The store lists restored folders itself so expansion survives
            // reloads even while no outline is attached; the observer only
            // mirrors the expansion on screen.
            for node in toExpand where (node.children == nil || node.isStale) && !loadingPaths.contains(node.path) {
                recursiveLoads.append(node.path)
            }
            notifyObservers { $0.fileExplorerTree(self, expand: toExpand) }
        }
        if !recursiveLoads.isEmpty {
            requestLoad(recursiveLoads)
        }
        if selectionTouched {
            notifyObservers { $0.fileExplorerTreeDidChangeSelection(self, scrollToAnchor: false) }
        }
        if let renamePath = pendingRenamePath, let node = nodesByPath[renamePath] {
            pendingRenamePath = nil
            selectedPath = node.path
            selectedPaths = [node.path]
            notifyObservers { $0.fileExplorerTreeDidChangeSelection(self, scrollToAnchor: true) }
            notifyObservers { $0.fileExplorerTree(self, beginRenaming: node) }
        }
        if let anchor = pendingScrollAnchor, let node = nodesByPath[anchor.path], isVisible(node) {
            pendingScrollAnchor = nil
            notifyObservers { $0.fileExplorerTree(self, restoreScrollTo: node, offset: anchor.offset) }
        }
    }

    private struct ChildrenApplication {
        var inserted: [FileExplorerNode] = []
        var updated: [FileExplorerNode] = []
        var revealedSelection = false
    }

    /// Rebuilds `parent`'s child array from the diff in `O(n)`: survivors keep
    /// their node objects, moved rows reuse theirs, only new paths allocate.
    private func applyChildren(
        _ entries: [FileTreeEntry],
        diff: FileTreeChildrenDiff,
        to parent: FileExplorerNode?
    ) -> ChildrenApplication {
        let old = parent?.children ?? (parent == nil ? rootNodes : [])
        var result = ChildrenApplication()
        var survivors: [FileExplorerNode] = []
        survivors.reserveCapacity(max(0, old.count - diff.removed.count))
        var removedByPath: [String: FileExplorerNode] = [:]
        for (index, node) in old.enumerated() {
            if diff.removed.contains(index) {
                removedByPath[node.path] = node
            } else {
                survivors.append(node)
            }
        }
        var next: [FileExplorerNode] = []
        next.reserveCapacity(entries.count)
        var survivorIndex = 0
        for (index, entry) in entries.enumerated() {
            let node: FileExplorerNode
            if diff.inserted.contains(index) {
                if let moved = removedByPath.removeValue(forKey: entry.path) {
                    node = moved
                    updateEntry(entry, of: node)
                } else if survivorIndex < survivors.count, survivors[survivorIndex].path == entry.path {
                    // Defensive: never duplicate a row object.
                    node = survivors[survivorIndex]
                    survivorIndex += 1
                } else {
                    node = FileExplorerNode(entry: entry, parent: parent, resourceContextID: resourceContextID)
                    nodesByPath[entry.path] = node
                    if selectedPaths.contains(entry.path) { result.revealedSelection = true }
                }
                result.inserted.append(node)
            } else {
                guard survivorIndex < survivors.count else { continue }
                node = survivors[survivorIndex]
                survivorIndex += 1
                if diff.updated.contains(index) {
                    updateEntry(entry, of: node)
                    result.updated.append(node)
                }
            }
            next.append(node)
        }
        for removed in removedByPath.values {
            unregisterSubtree(removed)
        }
        if let parent {
            parent.children = next
        } else {
            rootNodes = next
        }
        return result
    }

    private func updateEntry(_ entry: FileTreeEntry, of node: FileExplorerNode) {
        let wasDirectory = node.isDirectory
        node.update(entry: entry)
        if wasDirectory, !node.isDirectory {
            for child in node.children ?? [] { unregisterSubtree(child) }
            node.children = nil
        }
    }

    private func unregisterSubtree(_ node: FileExplorerNode) {
        if nodesByPath[node.path] === node {
            nodesByPath[node.path] = nil
        }
        loadingPaths.remove(node.path)
        if selectedPaths.remove(node.path) != nil, selectedPath == node.path {
            selectedPath = selectedPaths.first
        }
        for child in node.children ?? [] {
            unregisterSubtree(child)
        }
        if let session = treeSession, node.children != nil {
            let path = node.path
            Task { await session.engine.discard(subtreeAt: path) }
        }
    }

    // MARK: - Visibility

    /// Whether every ancestor of `node` is expanded, so its row is on screen.
    func isVisible(_ node: FileExplorerNode) -> Bool {
        var cursor = node.parent
        while let ancestor = cursor {
            if !expandedPaths.contains(ancestor.path) { return false }
            cursor = ancestor.parent
        }
        return true
    }

    /// Whether `node` is expanded and its children are on screen.
    func isVisiblyExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path) && isVisible(node)
    }

    private func isUnderRecursiveExpansion(_ node: FileExplorerNode) -> Bool {
        guard recursiveExpansionBudget > 0, !recursiveExpansionRoots.isEmpty else { return false }
        for root in recursiveExpansionRoots where Self.path(node.path, isContainedIn: root) {
            return true
        }
        return false
    }

    // MARK: - Expansion

    func expand(node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        let inserted = expandedPaths.insert(node.path).inserted
        if node.children == nil || node.isStale {
            if !loadingPaths.contains(node.path) {
                node.error = nil
                requestLoad([node.path])
            }
        }
        // Folders that changed while hidden under this one re-list now.
        var staleDescendants: [String] = []
        collectStaleExpandedDescendants(of: node, into: &staleDescendants)
        if !staleDescendants.isEmpty { requestLoad(staleDescendants) }
        if inserted { scheduleViewStateSave() }
    }

    private func collectStaleExpandedDescendants(of node: FileExplorerNode, into paths: inout [String]) {
        for child in node.children ?? [] where child.isDirectory && expandedPaths.contains(child.path) {
            if child.isStale || child.children == nil { paths.append(child.path) }
            collectStaleExpandedDescendants(of: child, into: &paths)
        }
    }

    /// Expands `node` and its subfolders as they load, like Option-clicking
    /// a Finder disclosure triangle, up to a fixed folder budget.
    func expandRecursively(node: FileExplorerNode) {
        guard node.isDirectory else { return }
        recursiveExpansionRoots.insert(node.path)
        recursiveExpansionBudget = recursiveExpansionDirectoryLimit
        var toExpand: [FileExplorerNode] = []
        var toLoad: [String] = []
        expandLoadedSubtree(node, toExpand: &toExpand, toLoad: &toLoad)
        expand(node: node)
        if !toLoad.isEmpty { requestLoad(toLoad) }
        if !toExpand.isEmpty {
            notifyObservers { $0.fileExplorerTree(self, expand: toExpand) }
        }
    }

    private func expandLoadedSubtree(
        _ node: FileExplorerNode,
        toExpand: inout [FileExplorerNode],
        toLoad: inout [String]
    ) {
        for child in node.children ?? [] where child.isDirectory && !child.isSymbolicLink {
            guard recursiveExpansionBudget > 0 else { return }
            if expandedPaths.insert(child.path).inserted {
                recursiveExpansionBudget -= 1
            }
            toExpand.append(child)
            if child.children == nil {
                toLoad.append(child.path)
            } else {
                expandLoadedSubtree(child, toExpand: &toExpand, toLoad: &toLoad)
            }
        }
    }

    func collapse(node: FileExplorerNode, recursively: Bool = false) {
        expandedPaths.remove(node.path)
        recursiveExpansionRoots.remove(node.path)
        if recursively {
            let prefix = node.path == "/" ? "/" : node.path + "/"
            expandedPaths = expandedPaths.filter { !$0.hasPrefix(prefix) }
        }
        if pendingDescendIntoFirstChildPath == node.path {
            pendingDescendIntoFirstChildPath = nil
        }
        scheduleViewStateSave()
    }

    func isExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path)
    }

    // MARK: - Selection

    func select(node: FileExplorerNode?) {
        let path = node?.path
        let paths = path.map { Set([$0]) } ?? []
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
        scheduleViewStateSave()
    }

    func select(nodes: [FileExplorerNode], anchor: FileExplorerNode?) {
        let paths = Set(nodes.map(\.path))
        let path = anchor?.path ?? nodes.first?.path
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
        scheduleViewStateSave()
    }

    /// Selects `path` once its row exists, expanding ancestors already loaded.
    func selectWhenAvailable(path: String) {
        selectedPath = path
        selectedPaths = [path]
        if nodesByPath[path] != nil {
            notifyObservers { $0.fileExplorerTreeDidChangeSelection(self, scrollToAnchor: true) }
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    // MARK: - Prefetch

    /// Lists a hovered remote folder after a short hover so expanding it is
    /// instant. Local listings are fast enough that prefetch only adds I/O.
    func prefetchChildren(for node: FileExplorerNode) {
        guard provider is any RemoteFileExplorerProvider,
              node.resourceContextID == nil || node.resourceContextID == resourceContextID,
              node.isDirectory, node.children == nil, !loadingPaths.contains(node.path) else { return }
        let path = node.path
        prefetchScheduler.schedule(after: .milliseconds(200)) { [weak self] in
            guard let self, let current = self.nodesByPath[path], current.children == nil,
                  !self.loadingPaths.contains(path) else { return }
            self.requestLoad([path], silent: true)
        }
    }

    func cancelPrefetch(for node: FileExplorerNode) {
        prefetchScheduler.cancel()
    }
}
