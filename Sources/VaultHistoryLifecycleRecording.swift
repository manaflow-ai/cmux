import Foundation

/// Lifecycle hooks that feed the History timeline. Call sites in
/// `TabManager` / `AppDelegate` stay one-liners; every hook here guards
/// suppression (session restore, app termination) and builds the event.
extension TabManager {
    func recordVaultHistoryWorkspaceCreated(_ workspace: Workspace) {
        guard !VaultHistoryEventLog.isRecordingSuppressed else { return }
        VaultHistoryEventLog.shared.record(VaultHistoryEvent(
            timestamp: Date(),
            kind: .workspaceCreated,
            title: resolvedWorkspaceDisplayTitle(for: workspace),
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                directory: workspace.currentDirectory
            )
        ))
    }

    func recordVaultHistoryWorkspaceRenamed(
        _ workspace: Workspace,
        previousTitle: String,
        currentTitle: String
    ) {
        guard !VaultHistoryEventLog.isRecordingSuppressed else { return }
        VaultHistoryEventLog.shared.record(VaultHistoryEvent(
            timestamp: Date(),
            kind: .workspaceRenamed,
            title: currentTitle,
            previousTitle: previousTitle,
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                directory: workspace.currentDirectory
            )
        ))
    }

    func recordVaultHistoryWorkspaceClosed(_ workspace: Workspace, closedItemId: UUID?) {
        guard !VaultHistoryEventLog.isRecordingSuppressed else { return }
        VaultHistoryEventLog.shared.record(VaultHistoryEvent(
            timestamp: Date(),
            kind: .workspaceClosed,
            title: resolvedWorkspaceDisplayTitle(for: workspace),
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                closedItemId: closedItemId,
                directory: workspace.currentDirectory
            )
        ))
    }
}

extension AppDelegate {
    func recordVaultHistoryWindowOpened(windowId: UUID) {
        guard !VaultHistoryEventLog.isRecordingSuppressed else { return }
        VaultHistoryEventLog.shared.record(VaultHistoryEvent(
            timestamp: Date(),
            kind: .windowOpened,
            title: "",
            subject: VaultHistorySubject(windowId: windowId)
        ))
    }

    /// Called from the same choke point that records closed-window restore
    /// history, so suppression (terminating app, session restore, explicit
    /// suppression sets) is already decided by the caller.
    func recordVaultHistoryWindowClosed(
        windowId: UUID,
        snapshot: SessionWindowSnapshot,
        closedItemId: UUID
    ) {
        let workspaces = snapshot.tabManager.workspaces
        let title = workspaces
            .compactMap { workspace -> String? in
                let candidate = workspace.customTitle ?? workspace.processTitle
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? ""
        VaultHistoryEventLog.shared.record(VaultHistoryEvent(
            timestamp: Date(),
            kind: .windowClosed,
            title: title,
            workspaceCount: workspaces.count,
            subject: VaultHistorySubject(
                windowId: windowId,
                closedItemId: closedItemId,
                directory: workspaces.first?.currentDirectory
            )
        ))
    }
}
