#if os(iOS) && DEBUG
import CmuxMobileModel
import Foundation

extension LiveCoordinator {
    /// DEBUG demo `live-new-chat`: a new agent chat tab with no session in `workspace`, as the
    /// Mac's New Tab makes one before its first send (`new-conversation-tab` with no session;
    /// hostd sets the tab's host to this Mac's own). Returns the tab's id once the Mac lists it.
    public func debugNewUnboundChat(in workspace: Workspace) async throws -> String {
        guard let owner = sessions[workspace.macID], let client = owner.workspaces.daemon,
              let pane = owner.tree?.panes[workspace.id] else {
            throw WorkspaceCreationError("Not connected")
        }
        let reply = try WorkspaceSync.check(await client.request("new-conversation-tab", params: [
            "pane": pane, "agent_session": ["harness": "claude"],
        ]))
        guard let surface = (reply["data"] as? [String: Any])?["surface"] as? Int else {
            throw WorkspaceCreationError("The Mac didn't say which tab it opened")
        }
        _ = try await owner.workspaces.listNow()
        return DaemonTree.tabID(surface: surface)
    }
}
#endif
