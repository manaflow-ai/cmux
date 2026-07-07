internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

// MARK: - Workspace actions (rename / pin / read-state / close / move / groups)
//
// The mobile-gated workspace mutations all re-sync from the Mac's authoritative
// workspace list after the request returns. That covers success, rejected
// actions (e.g. attempting to close the last workspace), and dropped push events.
extension MobileShellComposite {

    /// Rename a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. The refresh also runs after rejected/no-op actions so iOS
    /// can snap back to the Mac's real state.
    /// - Parameters:
    ///   - id: The workspace to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    /// - Returns: `success` when the Mac accepted the rename, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func renameWorkspace(
        id: MobileWorkspacePreview.ID,
        title: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else {
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(()) }
        var params = workspaceMutationParams(id: id)
        params["action"] = "rename"
        params["title"] = trimmed
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: "rename"
        )
    }

    /// Pin or unpin a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. The refresh also runs after rejected/no-op actions so iOS
    /// can snap back to the Mac's real state.
    /// - Parameters:
    ///   - id: The workspace to pin or unpin.
    ///   - pinned: `true` to pin, `false` to unpin.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspacePinned(
        id: MobileWorkspacePreview.ID,
        _ pinned: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else {
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        var params = workspaceMutationParams(id: id)
        params["action"] = pinned ? "pin" : "unpin"
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: pinned ? "pin" : "unpin"
        )
    }

    /// Mark a workspace read or unread on the Mac, then re-sync the authoritative
    /// list so the swipe label flips even if the push event is delayed.
    /// - Parameters:
    ///   - id: The workspace to mark.
    ///   - unread: `true` to mark unread, `false` to mark read.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceUnread(
        id: MobileWorkspacePreview.ID,
        _ unread: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsReadStateActions else {
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        var params = workspaceMutationParams(id: id)
        params["action"] = unread ? "mark_unread" : "mark_read"
        return await sendWorkspaceMutation(
            method: "workspace.action",
            params: params,
            id: id,
            actionName: unread ? "mark_unread" : "mark_read"
        )
    }

    /// Close a workspace on the Mac.
    ///
    /// Sends the mutation to the Mac, then re-syncs from the authoritative
    /// workspace list. If the Mac rejects the close, for example because it is
    /// the last workspace, the refresh restores the row state on iOS.
    /// - Parameter id: The workspace to close.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func closeWorkspace(
        id: MobileWorkspacePreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsCloseActions else {
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        return await sendWorkspaceMutation(
            method: "workspace.close",
            params: workspaceMutationParams(id: id),
            id: id,
            actionName: "close"
        )
    }

    /// Move a workspace to a new group/order on the Mac, then re-sync the list.
    /// - Parameters:
    ///   - id: The workspace to move.
    ///   - groupID: The target group, or `nil` to ungroup.
    ///   - beforeWorkspaceID: The workspace that should follow the moved row.
    ///   - movesGroup: Whether the moved row is a group header.
    /// - Returns: `success` when the Mac accepted the move, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func moveWorkspace(
        id: MobileWorkspacePreview.ID,
        toGroup groupID: MobileWorkspaceGroupPreview.ID?,
        before beforeWorkspaceID: MobileWorkspacePreview.ID?,
        movesGroup: Bool = false
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        guard workspaceActionCapabilities(for: id).supportsMoveActions else {
            return .failure(.unsupported(hostDisplayName: workspaceHostDisplayName(for: id)))
        }
        var params = workspaceMutationParams(id: id)
        if let groupID {
            params["group_id"] = groupID.rawValue
        }
        if let beforeWorkspaceID {
            params["before_workspace_id"] = remoteWorkspaceID(for: beforeWorkspaceID).rawValue
        }
        if movesGroup {
            params["move_group"] = true
        }
        return await sendWorkspaceMutation(
            method: "workspace.move",
            params: params,
            id: id,
            actionName: "move"
        )
    }

    /// Pin or unpin a workspace group on the Mac.
    /// - Parameters:
    ///   - id: The group to update.
    ///   - pinned: `true` to pin, `false` to unpin.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func setWorkspaceGroupPinned(
        id: MobileWorkspaceGroupPreview.ID,
        _ pinned: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(
            id: id,
            action: pinned ? "pin" : "unpin",
            title: nil,
            actionName: pinned ? "pin_group" : "unpin_group"
        )
    }

    /// Rename a workspace group on the Mac.
    /// - Parameters:
    ///   - id: The group to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func renameWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID,
        title: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(()) }
        return await sendWorkspaceGroupMutation(
            id: id,
            action: "rename",
            title: trimmed,
            actionName: "rename_group"
        )
    }

    /// Dissolve a workspace group on the Mac, keeping its workspaces.
    /// - Parameter id: The group to dissolve.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func ungroupWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(id: id, action: "ungroup", title: nil, actionName: "ungroup_group")
    }

    /// Delete a workspace group on the Mac, including its workspaces.
    /// - Parameter id: The group to delete.
    /// - Returns: `success` when the Mac accepted the request, otherwise the
    ///   failure the UI should surface.
    @discardableResult
    public func deleteWorkspaceGroup(
        id: MobileWorkspaceGroupPreview.ID
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        await sendWorkspaceGroupMutation(id: id, action: "delete", title: nil, actionName: "delete_group")
    }

    private func workspaceActionCapabilities(for id: MobileWorkspacePreview.ID) -> MobileWorkspaceActionCapabilities {
        workspaces.first { $0.id == id }?.actionCapabilities ?? .none
    }

    private func workspaceGroupActionCapabilities(for id: MobileWorkspaceGroupPreview.ID) -> MobileWorkspaceActionCapabilities {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return .none
        }
        return workspaceActionCapabilities(for: anchorWorkspaceID)
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        id: MobileWorkspacePreview.ID,
        actionName: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let target = workspaceMutationTarget(for: id)
        return await sendWorkspaceMutation(
            method: method,
            params: params,
            target: target,
            hostDisplayName: workspaceMutationHostDisplayName(
                target: target,
                fallback: workspaceHostDisplayName(for: id)
            ),
            logID: id.rawValue,
            actionName: actionName
        )
    }

    private func sendWorkspaceGroupMutation(
        id: MobileWorkspaceGroupPreview.ID,
        action: String,
        title: String?,
        actionName: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        let target = workspaceGroupMutationTarget(for: id)
        let hostDisplayName = workspaceGroupHostDisplayName(for: id, target: target)
        guard workspaceGroupActionCapabilities(for: id).supportsGroupActions else {
            return .failure(.unsupported(hostDisplayName: hostDisplayName))
        }
        var params: [String: Any] = ["group_id": id.rawValue, "action": action]
        if let title {
            params["title"] = title
        }
        return await sendWorkspaceMutation(
            method: "workspace.group.action",
            params: params,
            target: target,
            hostDisplayName: hostDisplayName,
            logID: id.rawValue,
            actionName: actionName
        )
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        target: WorkspaceMutationTarget,
        hostDisplayName: String?,
        logID: String,
        actionName: String
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        // Route the mutation to the Mac that actually OWNS this workspace. The
        // aggregated list can include rows from secondary Macs, whose connection is
        // not `remoteClient`; sending every mutation to the foreground client would
        // silently hit the wrong Mac (fail, or — with a colliding workspace id —
        // mutate a foreground workspace). The foreground path is unchanged for
        // foreground-owned (or single-Mac / anonymous) rows.
        guard let client = target.client else {
            // Owner is a known non-foreground Mac with no live connection: can't
            // deliver. Snap the row back to the authoritative state instead of
            // misrouting to the foreground Mac.
            await refreshWorkspaces()
            return .failure(.notConnected(hostDisplayName: hostDisplayName))
        }
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            _ = try await client.sendRequest(request)
        } catch {
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return .failure(.authorizationFailed(hostDisplayName: hostDisplayName))
            }
            // Only the foreground connection's health drives the foreground
            // unavailable/reconnect UI; a failed write to a secondary Mac must not
            // tear the foreground session down.
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            mobileShellLog.error("workspace mutation failed action=\(actionName, privacy: .public) id=\(logID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            await refreshAfterWorkspaceMutation(target)
            return .failure(workspaceMutationFailure(error, hostDisplayName: hostDisplayName))
        }
        // Re-sync the authoritative list for the Mac we actually mutated.
        await refreshAfterWorkspaceMutation(target)
        return .success(())
    }

    private func workspaceMutationParams(id: MobileWorkspacePreview.ID) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: id).rawValue,
            "client_id": clientID,
        ]
        if let windowID = workspaces.first(where: { $0.id == id })?.windowID {
            params["window_id"] = windowID
        }
        return params
    }

    private func workspaceGroupMutationTarget(for id: MobileWorkspaceGroupPreview.ID) -> WorkspaceMutationTarget {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return WorkspaceMutationTarget(
                client: remoteClient,
                isForeground: true,
                macDeviceID: foregroundMacDeviceID
            )
        }
        return workspaceMutationTarget(for: anchorWorkspaceID)
    }

    private func workspaceMutationFailure(
        _ error: any Error,
        hostDisplayName: String?
    ) -> MobileWorkspaceMutationFailure {
        guard let connectionError = error as? MobileShellConnectionError else {
            return .rejected(hostDisplayName: hostDisplayName)
        }
        switch connectionError {
        case .connectionClosed:
            return .notConnected(hostDisplayName: hostDisplayName)
        case .requestTimedOut:
            return .requestTimedOut(hostDisplayName: hostDisplayName)
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return .authorizationFailed(hostDisplayName: hostDisplayName)
        case let .rpcError(code, _):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required", "account_mismatch"].contains(normalizedCode) {
                return .authorizationFailed(hostDisplayName: hostDisplayName)
            }
            if normalizedCode == "unavailable" {
                return .notConnected(hostDisplayName: hostDisplayName)
            }
            return .rejected(hostDisplayName: hostDisplayName)
        case .invalidResponse:
            return .rejected(hostDisplayName: hostDisplayName)
        }
    }

    private func workspaceMutationHostDisplayName(
        target: WorkspaceMutationTarget,
        fallback: String?
    ) -> String? {
        if let macDeviceID = target.macDeviceID,
           let displayName = workspacesByMac[macDeviceID]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        let trimmedConnectedHostName = connectedHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isForeground, !trimmedConnectedHostName.isEmpty {
            return trimmedConnectedHostName
        }
        guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else {
            return nil
        }
        return fallback
    }

    private func workspaceHostDisplayName(for id: MobileWorkspacePreview.ID) -> String? {
        workspaces.first(where: { $0.id == id })?.macDisplayName
    }

    private func workspaceGroupHostDisplayName(
        for id: MobileWorkspaceGroupPreview.ID,
        target: WorkspaceMutationTarget
    ) -> String? {
        guard let anchorWorkspaceID = workspaceGroups.first(where: { $0.id == id })?.anchorWorkspaceID else {
            return workspaceMutationHostDisplayName(target: target, fallback: nil)
        }
        return workspaceMutationHostDisplayName(
            target: target,
            fallback: workspaceHostDisplayName(for: anchorWorkspaceID)
        )
    }

    /// Collapse or expand a workspace group on THIS device only.
    ///
    /// Folder collapse is a per-device UI preference, not shared state: collapsing
    /// a group on the phone must not collapse it on the Mac. So this records the
    /// choice in the device-local `groupCollapseStore` and updates the in-memory
    /// `workspaceGroups` for an immediate, authoritative render. Nothing is sent to
    /// the Mac, and a later Mac `workspace.updated` will not override it (the
    /// workspace-list ingest re-applies this store). The `async` signature is kept
    /// for call-site compatibility; the work is synchronous on the main actor.
    /// - Parameters:
    ///   - id: The group to collapse or expand.
    ///   - collapsed: `true` to collapse (hide members), `false` to expand.
    public func setWorkspaceGroupCollapsed(id: MobileWorkspaceGroupPreview.ID, _ collapsed: Bool) async {
        groupCollapseStore.set(id.rawValue, collapsed: collapsed)
        if let index = workspaceGroups.firstIndex(where: { $0.id == id }) {
            workspaceGroups[index].isCollapsed = collapsed
        }
    }
}
