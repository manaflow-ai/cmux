import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation

/// Opens a chat that moved to a machine (Move to Cloud, ``CloudMove``; Move Chat to SSH
/// Machine, ``SSHMove``): a new workspace on that machine with a terminal in `folder`, then
/// the chat's tab bound to `session` through the machine's store, selected; filed into the
/// window, and shown when the run may change the view. `mutationID` makes the chat tab's
/// creation idempotent.
@MainActor
enum MovedChatTab {
    static func open(_ session: String, harness: String?, on daemon: DaemonService, hostName: String, repair: EmptyWorkspaceRepair,
                     in folder: String, name: String?, mutationID: String, services: AppServices) async throws {
        guard let connection = daemon.connection, let host = AgentTabStore.registryHost(of: daemon) else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: host, hostName: hostName, session: session, harness: harness)
        let workspace = WorkspaceKey.generate()
        let created = try await WorkspaceCreation.createWithFirstTab(workspace, name: name, on: connection, repair: repair) { result in
            try await connection.createTerminal(in: result.key, cwd: folder)
            return try await connection.request(NewConversationTabRequest(agentSession: record, workspace: result.workspace,
                                                                          origin: AgentTabStore.createOrigin, mutationID: mutationID))
        }
        services.windows.reveal(workspaceID: workspace.rawValue)
        let tab = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        if let pane = await AgentSessionWorkspace.mirroredPane(of: workspace, in: daemon.store) {
            for window in services.windows.controllers { window.state.selection.select(tab, in: pane.id) }
        }
    }
}
