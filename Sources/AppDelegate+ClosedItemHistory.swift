import AppKit
import CmuxWorkspaces

/// Opaque, identity-stable handle for a live `TabManager`, hashing by
/// `ObjectIdentifier` so the package ``ClosedItemReopenCoordinator``'s manager
/// dedupe (`Set<TabManagerToken>`) reproduces the legacy `Set<ObjectIdentifier>`
/// guard exactly. The coordinator threads it without inspecting the manager.
@MainActor
struct TabManagerToken: Hashable {
    let manager: TabManager

    // Pointer-identity comparison/hash only — no main-actor state is read, so the
    // `Hashable`/`Equatable` witnesses are `nonisolated` (the conformance is used
    // from the package coordinator's `Set<Manager>` dedupe, off this type's
    // main-actor isolation).
    nonisolated static func == (lhs: TabManagerToken, rhs: TabManagerToken) -> Bool {
        lhs.manager === rhs.manager
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(manager))
    }
}

/// Opaque carrier for a store record the coordinator removed by id and may
/// re-insert if restoration fails. Wraps the app-target
/// `ClosedItemHistoryRecord` plus its original store index; the package threads
/// it through the reopen-by-id sequence without inspecting it.
@MainActor
struct ClosedItemRemovedHistoryRecord {
    let record: ClosedItemHistoryRecord
    let index: Int
}

// MARK: - Forwarding shims
// The recently-closed-history reopen/clear *routing* lives in the package
// `ClosedItemReopenCoordinator` (CmuxWorkspaces). These app-target entrypoints
// keep their legacy signatures and forward to the coordinator, translating the
// app's `TabManager?` into the opaque `TabManagerToken`. The genuinely
// app-coupled effects (the closed-item history store, the live `TabManager`
// registry, window creation/discard, focus) invert back through the
// `ClosedItemReopenHosting` conformance below; the `restoreClosedItem` entry
// switch and `activateMainWindowIfNeeded` focus step stay here because they
// reach `createMainWindow`/`discardMainWindowWithoutClosedHistory`/`NSWindow`
// (CONVENTIONS §6: AppKit/window-lifecycle reach stays in the executable target).
extension AppDelegate {
    func clearRecentlyClosedHistory(preferredTabManager: TabManager? = nil) {
        closedItemReopen.clearRecentlyClosedHistory(
            preferred: preferredTabManager.map(TabManagerToken.init)
        )
    }

    @discardableResult
    func reopenMostRecentlyClosedItem(
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        closedItemReopen.reopenMostRecentlyClosedItem(
            preferred: preferredTabManager.map(TabManagerToken.init),
            shouldActivate: shouldActivate
        )
    }

    @discardableResult
    func reopenClosedHistoryItem(
        id: UUID,
        preferredTabManager: TabManager? = nil,
        shouldActivate: Bool = true
    ) -> Bool {
        closedItemReopen.reopenClosedHistoryItem(
            id: id,
            preferred: preferredTabManager.map(TabManagerToken.init),
            shouldActivate: shouldActivate
        )
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
        for context in registeredMainWindows {
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
            guard windowEntry.snapshot.hasUsableRestoredContent(
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex,
                hasLivePanels: hasLivePanels
            ) else {
                if let originalWindowId {
                    closedItemHistory.remapWorkspaceWindowIds(from: windowId, to: originalWindowId)
                    closedItemHistory.flushPendingSaves()
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

    private func activateMainWindowIfNeeded(for manager: TabManager, shouldActivate: Bool) {
        guard shouldActivate,
              let windowId = windowId(for: manager) else {
            return
        }
        _ = environment.mainWindowRouter.focusMainWindow(windowId: windowId)
    }
}

// MARK: - ClosedItemReopenHosting (the reopen coordinator's effect seam)
// `ClosedItemReopenCoordinator` (CmuxWorkspaces) owns the routing sequence;
// these witnesses invert each app effect it reaches: the `closedItemHistory`
// store, the live `TabManager` registry and its legacy browser-panel stack, and
// the entry restoration / record re-insert that bottom out in the app-side
// `restoreClosedItem` switch above.
extension AppDelegate: ClosedItemReopenHosting {
    typealias Manager = TabManagerToken
    typealias RemovedRecord = ClosedItemRemovedHistoryRecord

    func removeAllClosedItemHistory() {
        closedItemHistory.removeAll()
    }

    func managersForClear(preferred: TabManagerToken?) -> [TabManagerToken] {
        var managers: [TabManager] = []
        if let preferred { managers.append(preferred.manager) }
        if let tabManager { managers.append(tabManager) }
        for context in registeredMainWindows {
            managers.append(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            if let routeManager = route.tabManager { managers.append(routeManager) }
        }
        return managers.map(TabManagerToken.init)
    }

    func clearRecentlyClosedBrowserPanelHistory(_ manager: TabManagerToken) {
        manager.manager.clearRecentlyClosedBrowserPanelHistory()
    }

    func recentlyClosedLegacyBrowserManagers(preferred: TabManagerToken?) -> [TabManagerToken] {
        recentlyClosedLegacyBrowserManagers(preferredTabManager: preferred?.manager)
            .map(TabManagerToken.init)
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt(_ manager: TabManagerToken) -> Date? {
        manager.manager.mostRecentLegacyClosedBrowserPanelClosedAt()
    }

    func restoreFirstRestorableStoreItem(
        newerThan cutoff: Date?,
        excluding: Set<UUID>,
        preferred: TabManagerToken?,
        shouldActivate: Bool
    ) -> ClosedItemReopenStoreRestoreOutcome {
        var failedRecordIds: Set<UUID> = []
        let didRestore = closedItemHistory.restoreFirstRestorable(
            newerThan: cutoff,
            excluding: excluding,
            onFailure: { failedRecordIds.insert($0) },
            using: { entry in
                self.restoreClosedItem(
                    entry,
                    preferredTabManager: preferred?.manager,
                    shouldActivate: shouldActivate
                )
            }
        )
        return ClosedItemReopenStoreRestoreOutcome(
            didRestore: didRestore,
            failedRecordIds: failedRecordIds
        )
    }

    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack(_ manager: TabManagerToken) -> Bool {
        manager.manager.reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    func removeStoreRecord(id: UUID) -> ClosedItemRemovedHistoryRecord? {
        guard let removed = closedItemHistory.removeRecord(id: id) else { return nil }
        return ClosedItemRemovedHistoryRecord(record: removed.record, index: removed.index)
    }

    func restoreRemovedRecord(
        _ removed: ClosedItemRemovedHistoryRecord,
        preferred: TabManagerToken?,
        shouldActivate: Bool
    ) -> Bool {
        restoreClosedItem(
            removed.record.entry,
            preferredTabManager: preferred?.manager,
            shouldActivate: shouldActivate
        )
    }

    func reinsertRemovedRecord(_ removed: ClosedItemRemovedHistoryRecord) {
        closedItemHistory.insert(removed.record, at: removed.index)
    }
}
