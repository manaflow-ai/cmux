import Foundation

extension TabManager {
    static func isCloudVMSessionRestoreWorkspace(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        isManagedCloudVMSessionRestoreWorkspace(snapshot)
    }

    static func isManagedCloudVMSessionRestoreWorkspace(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        guard let managedCloudVMID = snapshot.remote?.managedCloudVMID else { return false }
        return !managedCloudVMID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Any workspace that hosts a Cloud machine through either transport: the
    /// legacy managed remote (`managedCloudVMID`) or the cmux-tui binding
    /// (`cloudVM`). `DisableCloud` drops every one of these from restore; the
    /// one-machine normalization above deliberately keeps cmux-tui workspaces.
    static func isCloudVMWorkspaceSnapshotForManagedPolicy(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        isManagedCloudVMSessionRestoreWorkspace(snapshot) || snapshot.cloudVM != nil
    }

    /// Reconciles task-create provenance only when the caller owns a cache.
    /// A nil cache intentionally leaves unrelated snapshot restores isolated.
    static func recordRestoredTaskCreateProvenance(
        for workspace: Workspace,
        in cache: TerminalController.WorkspaceCreateIdempotencyCache?
    ) {
        guard let operationID = workspace.taskCreateOperationID, let cache else { return }
        cache.record(operationID: operationID, workspaceID: workspace.id)
    }
}
