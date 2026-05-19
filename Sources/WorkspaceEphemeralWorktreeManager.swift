import Bonsplit
import Foundation

@MainActor
final class WorkspaceEphemeralWorktreeManager {
    var recordsByPanelId: [UUID: EphemeralWorktreeRecord] = [:]

    private var windowCloseCleanupAuthorizedPanelIds: Set<UUID> = []
    private var pendingCloseConfirmTabIds: Set<TabID> = []
    private var pendingCloseConfirmPaneIds: Set<UUID> = []
    private var cleanupAuthorizedTabIds: Set<TabID> = []
    private var cleanupAuthorizedPaneIds: Set<UUID> = []

    func activeSessionIds() -> Set<String> {
        Set(recordsByPanelId.values.map(\.sessionId))
    }

    func prune(validPanelIds: Set<UUID>) {
        recordsByPanelId = recordsByPanelId.filter { validPanelIds.contains($0.key) }
    }

    func shouldConfirmClose(panelId: UUID) -> Bool {
        recordsByPanelId[panelId]?.cleanupPolicy == .block
    }

    func authorizeWindowClose(panelIds: Set<UUID>) {
        windowCloseCleanupAuthorizedPanelIds.formUnion(panelIds)
    }

    func cancelWindowClose(panelIds: Set<UUID>) {
        windowCloseCleanupAuthorizedPanelIds.subtract(panelIds)
    }

    func consumeWindowCloseAuthorizedPanelIds(additionalPanelIds: Set<UUID>) -> Set<UUID> {
        let authorized = additionalPanelIds.union(windowCloseCleanupAuthorizedPanelIds)
        windowCloseCleanupAuthorizedPanelIds.removeAll()
        return authorized
    }

    func authorizeTabCleanup(_ tabId: TabID) {
        cleanupAuthorizedTabIds.insert(tabId)
    }

    func cancelTabCleanup(_ tabId: TabID) {
        cleanupAuthorizedTabIds.remove(tabId)
    }

    func consumeTabCleanupAuthorization(_ tabId: TabID) -> Bool {
        cleanupAuthorizedTabIds.remove(tabId) != nil
    }

    func authorizePaneCleanup(_ paneId: PaneID) {
        cleanupAuthorizedPaneIds.insert(paneId.id)
    }

    func cancelPaneCleanup(_ paneId: PaneID) {
        cleanupAuthorizedPaneIds.remove(paneId.id)
    }

    func consumePaneCleanupAuthorization(_ paneId: PaneID) -> Bool {
        cleanupAuthorizedPaneIds.remove(paneId.id) != nil
    }

    func isTabConfirmationPending(_ tabId: TabID) -> Bool {
        pendingCloseConfirmTabIds.contains(tabId)
    }

    func beginTabConfirmation(_ tabId: TabID) {
        pendingCloseConfirmTabIds.insert(tabId)
    }

    func endTabConfirmation(_ tabId: TabID) {
        pendingCloseConfirmTabIds.remove(tabId)
    }

    func isPaneConfirmationPending(_ paneId: PaneID) -> Bool {
        pendingCloseConfirmPaneIds.contains(paneId.id)
    }

    func beginPaneConfirmation(_ paneId: PaneID) {
        pendingCloseConfirmPaneIds.insert(paneId.id)
    }

    func endPaneConfirmation(_ paneId: PaneID) {
        pendingCloseConfirmPaneIds.remove(paneId.id)
    }
}
