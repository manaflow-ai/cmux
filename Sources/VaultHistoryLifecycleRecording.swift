import CmuxVaultHistory
import Foundation

/// Lifecycle hooks that feed the Vault History timeline. Call sites in
/// `TabManager` / `AppDelegate` stay one-liners; every hook here guards
/// suppression (session restore, app termination) and builds the event.
extension TabManager {
    func recordVaultHistoryWorkspaceCreated(_ workspace: Workspace) {
        vaultHistoryEventLog?.record(VaultHistoryEvent(
            timestamp: .now,
            kind: .workspaceCreated,
            title: resolvedWorkspaceDisplayTitle(for: workspace),
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: windowId,
                directory: workspace.currentDirectory
            )
        ))
    }

    func recordVaultHistoryWorkspaceRenamed(
        _ workspace: Workspace,
        previousTitle: String,
        currentTitle: String
    ) {
        vaultHistoryEventLog?.record(VaultHistoryEvent(
            timestamp: .now,
            kind: .workspaceRenamed,
            title: currentTitle,
            previousTitle: previousTitle,
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: windowId,
                directory: workspace.currentDirectory
            )
        ))
    }

    func recordVaultHistoryWorkspaceClosed(_ workspace: Workspace) {
        vaultHistoryEventLog?.record(VaultHistoryEvent(
            timestamp: .now,
            kind: .workspaceClosed,
            title: resolvedWorkspaceDisplayTitle(for: workspace),
            subject: VaultHistorySubject(
                workspaceId: workspace.id,
                windowId: windowId,
                directory: workspace.currentDirectory
            )
        ))
    }
}

extension AppDelegate {
    func recordVaultHistoryWindowOpened(windowId: UUID) {
        vaultHistoryEventLog?.record(VaultHistoryEvent(
            timestamp: .now,
            kind: .windowOpened,
            title: "",
            subject: VaultHistorySubject(windowId: windowId)
        ))
    }

    /// Called from the same choke point that records closed-window restore
    /// history, so suppression (terminating app, session restore, explicit
    /// suppression sets) is already decided by the caller.
    func recordVaultHistoryWindowClosed(windowId: UUID, snapshot: SessionWindowSnapshot) {
        let workspaces = snapshot.tabManager.workspaces
        let title = workspaces
            .compactMap { workspace -> String? in
                let candidate = workspace.customTitle ?? workspace.processTitle
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .first ?? ""
        vaultHistoryEventLog?.record(VaultHistoryEvent(
            timestamp: .now,
            kind: .windowClosed,
            title: title,
            workspaceCount: workspaces.count,
            subject: VaultHistorySubject(windowId: windowId)
        ))
    }
}
