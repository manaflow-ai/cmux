import Foundation

/// Pure navigation-path policy for the compact (stacked) workspace shell.
///
/// Decides how a `NavigationStack` path should change when the selected workspace
/// changes or when a brand-new workspace is created, without referencing any view
/// or store. Generic over the workspace identifier so it can be tested with any
/// `Hashable` ID type.
public struct WorkspaceShellCompactNavigationPolicy {
    public init() {}

    /// Computes the navigation path after the selected workspace changes.
    /// - Parameters:
    ///   - currentPath: The current navigation path.
    ///   - selectedWorkspaceID: The newly selected workspace, or `nil` to clear.
    /// - Returns: The path to apply. Stays empty when the user is at the root,
    ///   clears when the authoritative selection clears, and retargets when the
    ///   store selects a different workspace. Transient workspace-list omissions
    ///   are handled by ``pathForVisibleWorkspaceIDsChange``.
    public func pathForSelectionChange<ID: Hashable>(
        currentPath: [ID],
        selectedWorkspaceID: ID?,
        visibleWorkspaceIDs: Set<ID> = []
    ) -> [ID] {
        guard !currentPath.isEmpty else {
            return currentPath
        }
        guard let selectedWorkspaceID else {
            return []
        }
        guard currentPath.last != selectedWorkspaceID else {
            return currentPath
        }
        return [selectedWorkspaceID]
    }

    /// Computes the navigation path when a workspace was just created, pushing it
    /// only when it is genuinely new.
    /// - Parameters:
    ///   - currentPath: The current navigation path.
    ///   - selectedWorkspaceID: The selected workspace, expected to be the created one.
    ///   - existingWorkspaceIDs: The workspaces that existed before creation, or `nil` when no create is pending.
    /// - Returns: The path to push for a newly created workspace, or `nil` when there is nothing to push.
    public func pathForCreatedWorkspaceSelection<ID: Hashable>(
        currentPath: [ID],
        selectedWorkspaceID: ID?,
        existingWorkspaceIDs: Set<ID>?
    ) -> [ID]? {
        guard let existingWorkspaceIDs,
              let selectedWorkspaceID,
              !existingWorkspaceIDs.contains(selectedWorkspaceID) else {
            return nil
        }
        guard currentPath.last != selectedWorkspaceID else {
            return currentPath
        }
        return [selectedWorkspaceID]
    }

    /// Computes the navigation path after the workspace list's visible IDs
    /// change. Keep the current detail route mounted while the routed workspace
    /// is still selected, even if a transient list refresh omits it while the
    /// terminal arrives. If the authoritative selection has moved away, pop or
    /// remap to the selected visible workspace so deleted workspaces do not stay
    /// mounted from a stale route snapshot.
    public func pathForVisibleWorkspaceIDsChange<ID: Hashable>(
        currentPath: [ID],
        visibleWorkspaceIDs: Set<ID>,
        selectedWorkspaceID: ID?
    ) -> [ID] {
        guard let currentDetailID = currentPath.last else {
            return currentPath
        }
        guard !visibleWorkspaceIDs.contains(currentDetailID) else {
            return currentPath
        }
        guard selectedWorkspaceID != currentDetailID else {
            return currentPath
        }
        if let selectedWorkspaceID,
           visibleWorkspaceIDs.contains(selectedWorkspaceID) {
            return [selectedWorkspaceID]
        }
        return currentPath.filter { visibleWorkspaceIDs.contains($0) }
    }
}
