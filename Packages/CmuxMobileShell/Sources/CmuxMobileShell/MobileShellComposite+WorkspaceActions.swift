internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

// MARK: - Workspace actions (rename / pin / group collapse)
//
// The mobile-gated workspace mutations, all fire-and-forget against the Mac's
// authoritative state: the Mac applies the mutation and its workspace-list
// observer pushes `workspace.updated`, which refreshes the list. No local
// optimistic copies, so overlapping actions can never leave stale state.
extension MobileShellComposite {

    /// Rename a workspace on the Mac.
    ///
    /// Fire-and-forget against the authoritative state: the Mac applies the title
    /// and its workspace-list observer pushes `workspace.updated`, which refreshes
    /// this list. No local optimistic mutation, so overlapping actions can never
    /// leave stale state.
    /// - Parameters:
    ///   - id: The workspace to rename.
    ///   - title: The new title. Whitespace-only titles are ignored.
    public func renameWorkspace(id: MobileWorkspacePreview.ID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.action",
                params: [
                    "workspace_id": id.rawValue,
                    "action": "rename",
                    "title": trimmed,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("workspace rename failed id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Pin or unpin a workspace on the Mac.
    ///
    /// Fire-and-forget against the authoritative state: the Mac toggles the pin
    /// and its workspace-list observer (which watches `$isPinned`) pushes
    /// `workspace.updated`, which refreshes this list. No local optimistic
    /// mutation, so overlapping pin/unpin taps can never leave stale state.
    /// - Parameters:
    ///   - id: The workspace to pin or unpin.
    ///   - pinned: `true` to pin, `false` to unpin.
    public func setWorkspacePinned(id: MobileWorkspacePreview.ID, _ pinned: Bool) async {
        guard let client = remoteClient else { return }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.action",
                params: [
                    "workspace_id": id.rawValue,
                    "action": pinned ? "pin" : "unpin",
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
        } catch {
            mobileShellLog.error("workspace pin failed id=\(id.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
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
