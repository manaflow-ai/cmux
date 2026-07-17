import AppKit

@MainActor
final class UndoableTerminalCloseStore {
    static let shared = UndoableTerminalCloseStore()

    private struct PendingClose {
        let id: UUID
        let restore: @MainActor () -> Bool
        let finalize: @MainActor () -> Void
        var expirationTask: Task<Void, Never>?
    }

    private var pendingCloses: [PendingClose] = []

    @discardableResult
    func stage(
        gracePeriod: TimeInterval,
        restore: @escaping @MainActor () -> Bool,
        finalize: @escaping @MainActor () -> Void
    ) -> UUID? {
        guard gracePeriod > 0 else {
            finalize()
            return nil
        }

        let id = UUID()
        pendingCloses.append(PendingClose(id: id, restore: restore, finalize: finalize))
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(gracePeriod))
            guard !Task.isCancelled else { return }
            self?.expire(id: id)
        }
        pendingCloses[pendingCloses.count - 1].expirationTask = task
        return id
    }

    @discardableResult
    func restoreMostRecent() -> Bool {
        guard var pending = pendingCloses.popLast() else { return false }
        pending.expirationTask?.cancel()
        pending.expirationTask = nil
        guard pending.restore() else {
            pending.finalize()
            return false
        }
        return true
    }

    func expire(id: UUID) {
        guard let index = pendingCloses.firstIndex(where: { $0.id == id }) else { return }
        var pending = pendingCloses.remove(at: index)
        pending.expirationTask?.cancel()
        pending.expirationTask = nil
        pending.finalize()
    }

    var pendingCount: Int { pendingCloses.count }
}

extension AppDelegate {
    func clearRecentlyClosedHistory(preferredTabManager: TabManager? = nil) {
        ClosedItemHistoryStore.shared.removeAll()

        var clearedManagers: Set<ObjectIdentifier> = []
        func clear(_ manager: TabManager?) {
            guard let manager else { return }
            guard clearedManagers.insert(ObjectIdentifier(manager)).inserted else { return }
            manager.clearRecentlyClosedBrowserPanelHistory()
        }

        clear(preferredTabManager)
        clear(tabManager)
        for context in mainWindowContexts.values {
            clear(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            clear(route.tabManager)
        }
    }

    @discardableResult
    func reopenMostRecentlyClosedItem(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        if UndoableTerminalCloseStore.shared.restoreMostRecent() {
            return true
        }

        var failedStoreRecordIds: Set<UUID> = []
        let restoreStoreItem: (Date?) -> Bool = { cutoff in
            ClosedItemHistoryStore.shared.restoreFirstRestorable(
                newerThan: cutoff,
                excluding: failedStoreRecordIds,
                onFailure: { failedStoreRecordIds.insert($0) },
                using: { entry in
                    self.restoreClosedItem(
                        entry,
                        preferredTabManager: preferredTabManager,
                        shouldActivate: shouldActivate
                    )
                }
            )
        }

        for manager in recentlyClosedLegacyBrowserManagers(preferredTabManager: preferredTabManager) {
            guard let closedAt = manager.mostRecentLegacyClosedBrowserPanelClosedAt() else {
                continue
            }
            if restoreStoreItem(closedAt) {
                return true
            }
            if manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack() {
                return true
            }
        }

        return restoreStoreItem(nil)
    }

    private func recentlyClosedLegacyBrowserManagers(preferredTabManager: TabManager?) -> [TabManager] {
        var managers: [TabManager] = []
        var seen: Set<ObjectIdentifier> = []

        func append(_ manager: TabManager?) {
            guard let manager else { return }
            guard manager.mostRecentLegacyClosedBrowserPanelClosedAt() != nil else { return }
            guard seen.insert(ObjectIdentifier(manager)).inserted else { return }
            managers.append(manager)
        }

        append(preferredTabManager)
        append(tabManager)
        for context in mainWindowContexts.values {
            append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            append(route.tabManager)
        }

        return managers.sorted { lhs, rhs in
            let lhsDate = lhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            let rhsDate = rhs.mostRecentLegacyClosedBrowserPanelClosedAt() ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    @discardableResult
    private func restoreClosedItem(
        _ entry: ClosedItemHistoryEntry,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool
    ) -> Bool {
        switch entry {
        case .panel(let panelEntry):
            let manager =
                tabManagerFor(tabId: panelEntry.workspaceId)
                ?? preferredTabManager
                ?? tabManager
            guard let manager, manager.restoreClosedPanel(panelEntry) else {
                return false
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
        case .workspace(let workspaceEntry):
            let manager =
                workspaceEntry.windowId.flatMap { tabManagerFor(windowId: $0) }
                ?? preferredTabManager
                ?? tabManager
            guard let manager, manager.restoreClosedWorkspace(workspaceEntry) else {
                return false
            }
            activateMainWindowIfNeeded(for: manager, shouldActivate: shouldActivate)
            return true
        case .window(let windowEntry):
            var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
            var restoredTabManager: TabManager?
            var windowSnapshot = windowEntry.snapshot
            if windowSnapshot.windowId == nil {
                windowSnapshot.windowId = windowEntry.windowId
            }
            let originalWindowId = windowSnapshot.windowId
            let originalWorkspaceIdsByIndex = windowSnapshot.tabManager.workspaces.enumerated().map { index, workspaceSnapshot -> UUID? in
                if let workspaceId = workspaceSnapshot.workspaceId {
                    return workspaceId
                }
                guard windowEntry.workspaceIds.indices.contains(index) else { return nil }
                return windowEntry.workspaceIds[index]
            }
            let windowId = createMainWindow(
                sessionWindowSnapshot: windowSnapshot,
                shouldActivate: shouldActivate,
                remapClosedPanelHistoryFromSessionSnapshot: false,
                excludingStableIdentitiesFromSessionSnapshot: liveStableIdentitySet(),
                restoredSessionSnapshotHandler: { panelIdsByWorkspaceIndex, tabManager in
                    restoredPanelIdsByWorkspaceIndex = panelIdsByWorkspaceIndex
                    restoredTabManager = tabManager
                }
            )
            let hasLivePanels = restoredTabManager?.tabs.contains { !$0.panels.isEmpty } == true
            guard ClosedWindowRestoreValidation.hasUsableRestoredContent(
                snapshot: windowEntry.snapshot,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex,
                hasLivePanels: hasLivePanels
            ) else {
                if let originalWindowId {
                    ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: windowId, to: originalWindowId)
                    ClosedItemHistoryStore.shared.flushPendingSaves()
                }
                discardMainWindowWithoutClosedHistory(windowId: windowId)
                return false
            }
            restoredTabManager?.remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: originalWorkspaceIdsByIndex,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
            return true
        }
    }

    @discardableResult
    func reopenClosedHistoryItem(
        id: UUID,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        if restoreClosedItem(
            removed.record.entry,
            preferredTabManager: preferredTabManager,
            shouldActivate: shouldActivate
        ) {
            return true
        }

        ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        return false
    }

    private func activateMainWindowIfNeeded(for manager: TabManager, shouldActivate: Bool) {
        guard shouldActivate,
              let windowId = windowId(for: manager) else {
            return
        }
        _ = focusMainWindow(windowId: windowId)
    }
}
