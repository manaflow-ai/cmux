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

    func resolvedWorkingDirectory(
        explicitWorkingDirectory: String?,
        worktree: EphemeralWorktreeRecord?,
        panelDirectory: String?,
        requestedWorkingDirectory: String?,
        workspaceDirectory: String?
    ) -> String? {
        if let explicit = Self.nonEmptyPath(explicitWorkingDirectory) {
            return explicit
        }

        if let worktreePath = Self.nonEmptyPath(worktree?.worktreePath) {
            if let panelDirectory = Self.nonEmptyPath(panelDirectory),
               Self.isPath(panelDirectory, inside: worktreePath) {
                return panelDirectory
            }
            if let requestedWorkingDirectory = Self.nonEmptyPath(requestedWorkingDirectory),
               Self.isPath(requestedWorkingDirectory, inside: worktreePath) {
                return requestedWorkingDirectory
            }
            return worktreePath
        }

        return Self.nonEmptyPath(panelDirectory)
            ?? Self.nonEmptyPath(requestedWorkingDirectory)
            ?? Self.nonEmptyPath(workspaceDirectory)
    }

    func resolvedRestoredWorkingDirectory(
        savedWorkingDirectory: String?,
        worktree: EphemeralWorktreeRecord?
    ) -> String? {
        resolvedWorkingDirectory(
            explicitWorkingDirectory: nil,
            worktree: worktree,
            panelDirectory: savedWorkingDirectory,
            requestedWorkingDirectory: nil,
            workspaceDirectory: savedWorkingDirectory
        )
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

    nonisolated static func closeConfirmationCopy(affectedCount: Int) -> (title: String, message: String) {
        let count = max(affectedCount, 1)
        if count == 1 {
            return (
                String(
                    localized: "dialog.ephemeralWorktree.close.title.one",
                    defaultValue: "Close isolated worktree session?"
                ),
                String(
                    localized: "dialog.ephemeralWorktree.close.message.one",
                    defaultValue: "This isolated worktree is configured to preserve changes before cleanup. Close to preserve any uncommitted changes and remove the worktree, or cancel to keep the session open."
                )
            )
        }

        let titleFormat = String(
            localized: "dialog.ephemeralWorktree.close.title.other",
            defaultValue: "Close %lld isolated worktree sessions?"
        )
        let messageFormat = String(
            localized: "dialog.ephemeralWorktree.close.message.other",
            defaultValue: "These %lld isolated worktrees are configured to preserve changes before cleanup. Close to preserve any uncommitted changes and remove the worktrees, or cancel to keep the sessions open."
        )
        return (
            String(format: titleFormat, locale: .current, Int64(count)),
            String(format: messageFormat, locale: .current, Int64(count))
        )
    }

    private nonisolated static func nonEmptyPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private nonisolated static func isPath(_ candidate: String, inside root: String) -> Bool {
        let candidatePath = (candidate as NSString).standardizingPath
        let rootPath = (root as NSString).standardizingPath
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
