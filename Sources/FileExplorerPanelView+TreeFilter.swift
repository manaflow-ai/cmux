import AppKit

@MainActor
extension FileExplorerPanelView.Coordinator {
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
            fileFilter.rebuildIndex(nodes: store.rootNodes)
            fileFilterTreeRevision = store.treeRevision
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
            query: fileFilter.query,
            treeRevision: fileFilterTreeRevision,
            outlineView: outlineView
        )
    }

    private func startFileFilterTask(
        snapshot: FileExplorerTreeFilterSnapshot,
        query: String,
        treeRevision: Int,
        outlineView: NSOutlineView
    ) {
        fileFilterTask?.cancel()
        fileFilterGeneration &+= 1
        let generation = fileFilterGeneration
        fileFilterTask = Task { [weak self, weak outlineView] in
            do {
                let result = try await snapshot.filter(query: query)
                try Task.checkCancellation()
                guard let self, let outlineView,
                      self.fileFilterGeneration == generation else { return }
                self.fileFilterTask = nil
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
