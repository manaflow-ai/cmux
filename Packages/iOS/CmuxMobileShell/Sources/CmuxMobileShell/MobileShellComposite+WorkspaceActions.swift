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
        await sendWorkspaceMutation(
            method: "workspace.close",
            params: workspaceMutationParams(id: id),
            id: id,
            actionName: "close"
        )
    }

    private func sendWorkspaceMutation(
        method: String,
        params: [String: Any],
        id: MobileWorkspacePreview.ID,
        actionName: String
    ) async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: method,
                params: params
            )
            _ = try await client.sendRequest(request)
        } catch {
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            mobileShellLog.error("workspace mutation failed action=\(actionName, privacy: .public) id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        await refreshWorkspaces()
    }

    private func workspaceMutationParams(id: MobileWorkspacePreview.ID) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": id.rawValue,
            "client_id": clientID,
        ]
        if let windowID = workspaces.first(where: { $0.id == id })?.windowID {
            params["window_id"] = windowID
        }
        return params
    }

    /// Collapse or expand a workspace group on the Mac.
    ///
    /// Fire-and-forget against the authoritative state, mirroring pin/rename: the
    /// Mac toggles the group's `isCollapsed` and its workspace-list observer
    /// (which watches `$workspaceGroups`) pushes `workspace.updated`, which
    /// refreshes this list with the new collapse state. No local optimistic
    /// mutation, so overlapping collapse/expand taps can never leave stale state.
    /// - Parameters:
    ///   - id: The group to collapse or expand.
    ///   - collapsed: `true` to collapse (hide members), `false` to expand.
    public func setWorkspaceGroupCollapsed(id: MobileWorkspaceGroupPreview.ID, _ collapsed: Bool) async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: collapsed ? "workspace.group.collapse" : "workspace.group.expand",
                params: [
                    "group_id": id.rawValue,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("workspace group collapse failed id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}
