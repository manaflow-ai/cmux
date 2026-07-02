internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

// MARK: - Workspace actions (rename / pin / read-state / close / group collapse)
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
    public func renameWorkspace(id: MobileWorkspacePreview.ID, title: String) async {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var params = workspaceMutationParams(id: id)
        params["action"] = "rename"
        params["title"] = trimmed
        await sendWorkspaceMutation(
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
    public func setWorkspacePinned(id: MobileWorkspacePreview.ID, _ pinned: Bool) async {
        guard workspaceActionCapabilities(for: id).supportsWorkspaceActions else { return }
        var params = workspaceMutationParams(id: id)
        params["action"] = pinned ? "pin" : "unpin"
        await sendWorkspaceMutation(
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
    public func setWorkspaceUnread(id: MobileWorkspacePreview.ID, _ unread: Bool) async {
        guard workspaceActionCapabilities(for: id).supportsReadStateActions else { return }
        var params = workspaceMutationParams(id: id)
        params["action"] = unread ? "mark_unread" : "mark_read"
        await sendWorkspaceMutation(
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
    public func closeWorkspace(id: MobileWorkspacePreview.ID) async {
        guard workspaceActionCapabilities(for: id).supportsCloseActions else { return }
        await sendWorkspaceMutation(
            method: "workspace.close",
            params: workspaceMutationParams(id: id),
            id: id,
            actionName: "close"
        )
    }

    /// Close a terminal surface on the Mac.
    ///
    /// Foreground Mac rows are removed optimistically: the row disappears (and,
    /// when it was the selected terminal, selection moves to its adjacent
    /// neighbor) before the Mac responds. The local snapshot rolls back on send
    /// failure or if no authoritative foreground refresh reconciles the close.
    /// - Parameters:
    ///   - workspaceID: The workspace containing the terminal.
    ///   - terminalID: The terminal surface to close.
    public func closeTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async {
        guard workspaceActionCapabilities(for: workspaceID).supportsTerminalCloseActions else { return }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.terminals.contains(where: { $0.id == terminalID }) else {
            return
        }
        // The Mac rejects closing a workspace's last surface; don't send a
        // mutation that can only fail (the picker sheet also hides the delete
        // affordance at one row, this guards the API path).
        guard workspace.terminals.count > 1 else { return }
        var params = workspaceMutationParams(id: workspaceID)
        params["surface_id"] = terminalID.rawValue
        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else {
            await refreshAfterWorkspaceMutation(target)
            return
        }
        let rollbackWorkspacesByMac = workspacesByMac
        let rollbackSelectedTerminalID = selectedTerminalID
        let canOptimisticallyRemove = target.isForeground
        if canOptimisticallyRemove {
            removeTerminalRowOptimistically(from: workspace, terminalID: terminalID)
        }
        let optimisticVersion = workspaceTopologyVersion
        func rollbackOptimisticRemoval() {
            guard canOptimisticallyRemove else { return }
            workspacesByMac = rollbackWorkspacesByMac
            selectedTerminalID = rollbackSelectedTerminalID
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "terminal.close",
                params: params
            )
            _ = try await client.sendRequest(request)
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else {
                rollbackOptimisticRemoval()
                return
            }
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            mobileShellLog.error("workspace mutation failed action=terminal_close id=\(workspaceID.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            rollbackOptimisticRemoval()
            return
        }
        await refreshAfterWorkspaceMutation(target)
        if canOptimisticallyRemove, workspaceTopologyVersion == optimisticVersion {
            rollbackOptimisticRemoval()
        }
    }

    /// Drop `terminalID`'s row from the per-Mac source of truth and, when it was
    /// the selected terminal, move selection to its adjacent neighbor (the next
    /// row, else the previous one) before any network round trip. Purely local:
    /// the caller's post-mutation re-sync snaps back to the Mac's authoritative
    /// list, restoring the row if the close was rejected.
    private func removeTerminalRowOptimistically(
        from workspace: MobileWorkspacePreview,
        terminalID: MobileTerminalPreview.ID
    ) {
        if selectedTerminalID == terminalID,
           let removedIndex = workspace.terminals.firstIndex(where: { $0.id == terminalID }) {
            let followers = workspace.terminals[(removedIndex + 1)...]
            let leaders = workspace.terminals[..<removedIndex].reversed()
            if let neighbor = followers.first ?? leaders.first {
                selectedTerminalID = neighbor.id
            }
        }
        // Match by the Mac-local id (aggregation scopes the flat row ids, while
        // the per-Mac entries keep original ids) plus terminal membership.
        let remoteID = workspace.rpcWorkspaceID
        for (macKey, state) in workspacesByMac {
            guard let workspaceIndex = state.workspaces.firstIndex(where: { candidate in
                (candidate.remoteWorkspaceID ?? candidate.id) == remoteID
                    && candidate.terminals.contains(where: { $0.id == terminalID })
            }) else { continue }
            var updatedState = state
            updatedState.workspaces[workspaceIndex].terminals.removeAll { $0.id == terminalID }
            workspacesByMac[macKey] = updatedState
            return
        }
    }

    private func workspaceActionCapabilities(for id: MobileWorkspacePreview.ID) -> MobileWorkspaceActionCapabilities {
        workspaces.first { $0.id == id }?.actionCapabilities ?? .none
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        id: MobileWorkspacePreview.ID,
        actionName: String
    ) async {
        // Route the mutation to the Mac that actually OWNS this workspace. The
        // aggregated list can include rows from secondary Macs, whose connection is
        // not `remoteClient`; sending every mutation to the foreground client would
        // silently hit the wrong Mac (fail, or — with a colliding workspace id —
        // mutate a foreground workspace). The foreground path is unchanged for
        // foreground-owned (or single-Mac / anonymous) rows.
        let target = workspaceMutationTarget(for: id)
        guard let client = target.client else {
            // Owner is a known non-foreground Mac with no live connection: can't
            // deliver. Snap the row back to the authoritative state instead of
            // misrouting to the foreground Mac.
            await refreshWorkspaces()
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: params
            )
            _ = try await client.sendRequest(request)
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            // Only the foreground connection's health drives the foreground
            // unavailable/reconnect UI; a failed write to a secondary Mac must not
            // tear the foreground session down.
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            mobileShellLog.error("workspace mutation failed action=\(actionName, privacy: .public) id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        // Re-sync the authoritative list for the Mac we actually mutated.
        await refreshAfterWorkspaceMutation(target)
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
