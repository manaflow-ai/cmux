import AppKit

@MainActor
extension FileExplorerPanelView.Coordinator {
    func suspendFileFilter() {
        cancelFileFilterTask(discardingPendingActions: true)
    }

    func invalidateFileFilterIndex() {
        cancelFileFilterTask(discardingPendingActions: true)
        fileFilter.invalidateIndex()
        fileFilterTreeRevision = -1
    }

    func setFileFilterQuery(
        _ query: String,
        in outlineView: NSOutlineView,
        afterApplying action: (() -> Void)? = nil
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasActive = fileFilter.isActive
        if !wasActive, !normalizedQuery.isEmpty {
            preFilterTopVisiblePath = topVisibleNode(in: outlineView)?.path
        }

        let queryChanged = fileFilter.setQuery(normalizedQuery)
        if queryChanged {
            cancelFileFilterTask(discardingPendingActions: true)
        }
        if let action {
            pendingFileFilterActions.append(action)
        }

        let treeChanged = fileFilterTreeRevision != store.treeRevision
        if treeChanged, fileFilter.isActive {
            let treeRevision = store.treeRevision
            let builder = FileExplorerTreeFilterSnapshotBuilder(nodes: store.rootNodes)
            if let captured = builder.buildSynchronously(
                upTo: FileExplorerTreeFilterSnapshot.synchronousNodeLimit
            ) {
                fileFilter.replaceIndex(
                    snapshot: captured.snapshot,
                    nodesByPath: captured.nodesByPath
                )
                fileFilterTreeRevision = treeRevision
            } else {
                startFileFilterTask(
                    snapshot: nil,
                    builder: builder,
                    query: fileFilter.query,
                    treeRevision: treeRevision,
                    outlineView: outlineView
                )
                return
            }
        }

        guard fileFilter.isActive else {
            if queryChanged || treeChanged {
                reloadFilteredTree(in: outlineView)
                if wasActive {
                    restorePreFilterScroll(in: outlineView)
                }
            } else {
                refreshFilteredRows(in: outlineView)
            }
            runPendingFileFilterActions()
            return
        }

        guard queryChanged || treeChanged || fileFilter.needsFiltering else {
            refreshFilteredRows(in: outlineView)
            runPendingFileFilterActions()
            return
        }
        if !queryChanged, !treeChanged, fileFilterTask != nil {
            return
        }

        let snapshot = fileFilter.snapshot
        if snapshot.nodeCount <= FileExplorerTreeFilterSnapshot.synchronousNodeLimit {
            fileFilterTask?.cancel()
            fileFilterTask = nil
            let result = snapshot.filterSynchronously(query: fileFilter.query)
            guard fileFilter.apply(result) else { return }
            reloadFilteredTree(in: outlineView)
            runPendingFileFilterActions()
            return
        }

        startFileFilterTask(
            snapshot: snapshot,
            builder: nil,
            query: fileFilter.query,
            treeRevision: fileFilterTreeRevision,
            outlineView: outlineView
        )
    }

    private func startFileFilterTask(
        snapshot: FileExplorerTreeFilterSnapshot?,
        builder: FileExplorerTreeFilterSnapshotBuilder?,
        query: String,
        treeRevision: Int,
        outlineView: NSOutlineView
    ) {
        fileFilterTask?.cancel()
        fileFilterGeneration &+= 1
        let generation = fileFilterGeneration
        fileFilterTask = Task { [weak self, weak outlineView] in
            do {
                var filterSnapshot = snapshot
                if let builder {
                    let captured = try await builder.build()
                    try Task.checkCancellation()
                    guard let coordinator = self, let outlineView,
                          coordinator.fileFilterGeneration == generation else { return }
                    guard coordinator.containerView?.displayedSearchScope == .names else {
                        coordinator.fileFilterTask = nil
                        return
                    }
                    guard treeRevision == coordinator.store.treeRevision else {
                        coordinator.fileFilterTask = nil
                        coordinator.setFileFilterQuery(coordinator.fileFilter.query, in: outlineView)
                        return
                    }
                    coordinator.fileFilter.replaceIndex(
                        snapshot: captured.snapshot,
                        nodesByPath: captured.nodesByPath
                    )
                    coordinator.fileFilterTreeRevision = treeRevision
                    filterSnapshot = captured.snapshot
                }

                guard let filterSnapshot else { return }
                let result = try await filterSnapshot.filter(query: query)
                try Task.checkCancellation()
                guard let self, let outlineView,
                      self.fileFilterGeneration == generation else { return }
                self.fileFilterTask = nil
                guard self.containerView?.displayedSearchScope == .names else { return }
                guard treeRevision == self.store.treeRevision else {
                    self.setFileFilterQuery(self.fileFilter.query, in: outlineView)
                    return
                }
                guard self.fileFilter.apply(result) else { return }
                self.reloadFilteredTree(in: outlineView)
                self.runPendingFileFilterActions()
            } catch is CancellationError {
                guard let self, self.fileFilterGeneration == generation else { return }
                self.fileFilterTask = nil
            } catch {
                guard let self, self.fileFilterGeneration == generation else { return }
                self.fileFilterTask = nil
            }
        }
    }

    private func cancelFileFilterTask(discardingPendingActions: Bool) {
        fileFilterTask?.cancel()
        fileFilterTask = nil
        fileFilterGeneration &+= 1
        if discardingPendingActions {
            pendingFileFilterActions.removeAll()
        }
    }

    private func runPendingFileFilterActions() {
        let actions = pendingFileFilterActions
        pendingFileFilterActions.removeAll()
        for action in actions {
            action()
        }
    }
}
