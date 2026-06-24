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

    /// Close a workspace on the Mac with an optimistic UI update.
    ///
    /// The row is removed from the local list immediately so the close feels
    /// instant, then the mutation is sent and the authoritative list re-synced.
    /// While the close is unconfirmed the id is filtered out of every applied
    /// snapshot (see ``optimisticallyClosedWorkspaces``), so a stale list fetched
    /// before the Mac processed the close cannot resurrect the row, and the real
    /// confirmation cannot double-remove it. If the transport call fails (offline
    /// or a rejected close, e.g. the last workspace) the row is restored before
    /// the re-sync so iOS snaps back to the Mac's real state.
    /// - Parameter id: The workspace to close.
    public func closeWorkspace(id: MobileWorkspacePreview.ID) async {
        guard workspaceActionCapabilities(for: id).supportsCloseActions else { return }
        let params = workspaceMutationParams(id: id)
        let target = workspaceMutationTarget(for: id)
        let removed = applyOptimisticWorkspaceClose(id: id)
        guard let client = target.client else {
            if removed { rollbackOptimisticWorkspaceClose(id: id) }
            await refreshWorkspaces()
            return
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.close",
                params: params
            )
            _ = try await client.sendRequest(request)
        } catch {
            if removed { rollbackOptimisticWorkspaceClose(id: id) }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            if target.isForeground {
                markMacConnectionUnavailableIfNeeded(after: error)
            }
            mobileShellLog.error("workspace mutation failed action=close id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        await refreshAfterWorkspaceMutation(target)
    }

    /// Remove a workspace from the local list immediately and record its snapshot
    /// for rollback. Returns `true` when a row was actually removed (so the caller
    /// only rolls back what it removed). Reselects a neighbor if the closed
    /// workspace was selected, matching the Mac's "select an adjacent tab" behavior.
    /// - Parameter id: The workspace to remove optimistically.
    /// - Returns: Whether a workspace was present and removed.
    @discardableResult
    func applyOptimisticWorkspaceClose(id: MobileWorkspacePreview.ID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let snapshot = workspaces[index]
        optimisticallyClosedWorkspaces[id] = snapshot
        let wasSelected = selectedWorkspaceID == id
        if wasSelected {
            optimisticallyClosedSelectedWorkspaceIDs.insert(id)
        } else {
            optimisticallyClosedSelectedWorkspaceIDs.remove(id)
        }
        if wasSelected {
            // Prefer the workspace that slid into the closed row's position, then
            // the previous neighbor, then any remaining workspace.
            let remaining = workspaces.filter { $0.id != id }
            let next: MobileWorkspacePreview?
            if index < remaining.count {
                next = remaining[index]
            } else if index - 1 >= 0, index - 1 < remaining.count {
                next = remaining[index - 1]
            } else {
                next = remaining.first
            }
            selectedWorkspaceID = next?.id
        }
        recomputeDerivedWorkspaceState()
        if wasSelected {
            syncSelectedTerminalForWorkspace()
        }
        return true
    }

    /// Restore an optimistically-closed workspace after a failed close, and drop
    /// its pending entry so the source-derived workspace list can show the row
    /// again.
    /// - Parameter id: The workspace whose close failed.
    func rollbackOptimisticWorkspaceClose(id: MobileWorkspacePreview.ID) {
        guard optimisticallyClosedWorkspaces.removeValue(forKey: id) != nil else {
            return
        }
        let wasSelected = optimisticallyClosedSelectedWorkspaceIDs.remove(id) != nil
        recomputeDerivedWorkspaceState()
        if (wasSelected || selectedWorkspaceID == nil), workspaces.contains(where: { $0.id == id }) {
            selectedWorkspaceID = id
            syncSelectedTerminalForWorkspace()
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
