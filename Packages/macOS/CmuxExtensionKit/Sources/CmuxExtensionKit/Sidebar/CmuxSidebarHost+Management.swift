import Foundation

extension CmuxSidebarHost {
    /// Creates a native group from workspaces or with a new anchor workspace.
    ///
    /// Requires `createWorkspaceGroup` and `createWorkspace`, because CMUX may
    /// create an anchor. Existing member sessions stay open.
    ///
    /// - Parameters:
    ///   - name: Proposed native group name.
    ///   - workspaceIDs: Existing members; empty by default for a new group.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func createWorkspaceGroup(name: String, workspaceIDs: [UUID] = []) async throws {
        try await send(.createWorkspaceGroup(name: name, workspaceIDs: workspaceIDs))
    }

    /// Renames a workspace or opens CMUX's native rename prompt.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace to rename, without changing selection first.
    ///   - title: Custom name; nil opens the prompt and an empty string clears it.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func renameWorkspace(workspaceID: UUID, title: String? = nil) async throws {
        try await send(.renameWorkspace(workspaceID: workspaceID, title: title))
    }

    /// Renames a surface or opens CMUX's native rename prompt.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace containing the target surface.
    ///   - surfaceID: Stable surface identifier from the snapshot.
    ///   - title: Custom name; nil opens the prompt and an empty string clears it.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func renameSurface(workspaceID: UUID, surfaceID: UUID, title: String? = nil) async throws {
        try await send(.renameSurface(workspaceID: workspaceID, surfaceID: surfaceID, title: title))
    }

    /// Renames a native group or opens CMUX's native rename prompt.
    ///
    /// - Parameters:
    ///   - groupID: Stable native group identifier.
    ///   - title: Nonempty group name, or nil to open the prompt.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func renameWorkspaceGroup(groupID: UUID, title: String? = nil) async throws {
        try await send(.renameWorkspaceGroup(groupID: groupID, title: title))
    }

    /// Applies a native workspace pin state.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace whose pin state should change.
    ///   - isPinned: Desired state, without toggling from a stale snapshot.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspacePinned(workspaceID: UUID, isPinned: Bool) async throws {
        try await send(.setWorkspacePinned(workspaceID: workspaceID, isPinned: isPinned))
    }

    /// Sets a workspace's importance independently of pinning and agent activity.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace receiving the marker.
    ///   - importance: Priority, follow-up, or none to clear the marker.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspaceImportance(
        workspaceID: UUID,
        importance: CmuxSidebarWorkspaceImportance
    ) async throws {
        try await send(.setWorkspaceImportance(workspaceID: workspaceID, importance: importance))
    }

    /// Expands or collapses a native workspace group.
    ///
    /// - Parameters:
    ///   - groupID: Native group whose expansion state should change.
    ///   - isCollapsed: Desired state, without toggling from a stale snapshot.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspaceGroupCollapsed(groupID: UUID, isCollapsed: Bool) async throws {
        try await send(.setWorkspaceGroupCollapsed(groupID: groupID, isCollapsed: isCollapsed))
    }

    /// Moves a workspace into a native group or removes its group assignment.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace to move without closing it.
    ///   - groupID: Destination group, or nil to remove the workspace from its group.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func moveWorkspaceToGroup(workspaceID: UUID, groupID: UUID?) async throws {
        try await send(.moveWorkspaceToGroup(workspaceID: workspaceID, groupID: groupID))
    }

    /// Dissolves a native group while retaining its member workspaces.
    ///
    /// - Parameter groupID: Group to dissolve; an empty pinned group stays protected.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func ungroupWorkspaceGroup(groupID: UUID) async throws {
        try await send(.ungroupWorkspaceGroup(groupID: groupID))
    }

    /// Requests native confirmation to delete a group and close its members.
    ///
    /// Requires both `deleteWorkspaceGroup` and `closeWorkspace`. CMUX captures
    /// the exact membership being confirmed. This does not delete files or folders.
    ///
    /// - Parameter groupID: Native group to delete after confirmation.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func deleteWorkspaceGroup(groupID: UUID) async throws {
        try await send(.deleteWorkspaceGroup(groupID: groupID))
    }

    /// Marks a workspace's native notification state as read.
    ///
    /// - Parameter workspaceID: Workspace whose read state should change.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func markWorkspaceRead(workspaceID: UUID) async throws {
        try await send(.markWorkspaceRead(workspaceID: workspaceID))
    }

    /// Marks a workspace's native notification state as unread.
    ///
    /// - Parameter workspaceID: Workspace whose unread state should change.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func markWorkspaceUnread(workspaceID: UUID) async throws {
        try await send(.markWorkspaceUnread(workspaceID: workspaceID))
    }

    /// Clears a workspace's latest native notification.
    ///
    /// - Parameter workspaceID: Workspace whose latest notification should clear.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func clearWorkspaceNotifications(workspaceID: UUID) async throws {
        try await send(.clearWorkspaceNotifications(workspaceID: workspaceID))
    }

    /// Applies a workspace's native notification mute state.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace to mute or unmute.
    ///   - isMuted: Desired mute state.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspaceMuted(workspaceID: UUID, isMuted: Bool) async throws {
        try await send(.setWorkspaceMuted(workspaceID: workspaceID, isMuted: isMuted))
    }

    /// Sets or clears a workspace's native custom description.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace receiving the description.
    ///   - description: Custom description, or nil to clear it.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspaceDescription(workspaceID: UUID, description: String?) async throws {
        try await send(.setWorkspaceDescription(workspaceID: workspaceID, description: description))
    }

    /// Sets or clears a workspace's native custom color.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace receiving the color.
    ///   - colorHex: Native hexadecimal color, or nil to restore the default.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func setWorkspaceColor(workspaceID: UUID, colorHex: String?) async throws {
        try await send(.setWorkspaceColor(workspaceID: workspaceID, colorHex: colorHex))
    }

    /// Requests a move within the native sidebar's valid ordering tiers.
    ///
    /// - Parameters:
    ///   - workspaceID: Workspace to reorder.
    ///   - beforeWorkspaceID: Workspace to precede, or nil for the end of its tier.
    /// - Throws: ``CmuxSidebarActionError`` on rejection or cancellation.
    public func moveWorkspace(workspaceID: UUID, beforeWorkspaceID: UUID?) async throws {
        try await send(.moveWorkspace(workspaceID: workspaceID, beforeWorkspaceID: beforeWorkspaceID))
    }
}
