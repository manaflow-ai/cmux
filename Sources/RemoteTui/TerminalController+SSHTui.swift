import CmuxCore
import CmuxFoundation
import Foundation

extension TerminalController {
    /// Network work suspends; only workspace/catalog mutations execute on the main actor.
    @MainActor
    func openSSHTuiWorkspace(params: [String: Any]) async throws -> [String: Any] {
        guard ManagedRemoteConnectionsPolicy.isEnabled else {
            throw SurfaceCatalogError.unsupported(ManagedRemoteConnectionsPolicy.disabledMessage)
        }
        var hostParams = params
        hostParams["host"] = params["destination"]
        guard let host = Self.remoteTmuxHost(from: hostParams),
              let coordinator = AppDelegate.shared?.sshTuiWorkspaceCoordinator else {
            throw SurfaceCatalogError.unsupported(String(localized: "socket.remoteTmux.hostRequired", defaultValue: "host is required"))
        }
        let options = params["ssh_options"] as? [String] ?? []
        let configuredCommand = params["configured_remote_command"] as? String
        guard let profile = WorkspaceRemoteTerminalProfile(remoteConfigurationValue: params["terminal_profile"] as? String,
                tmuxSessionName: params["terminal_tmux_session"] as? String) else { throw CloudDiagnosticFailure.unsupported }
        let configuration = WorkspaceRemoteConfiguration(
            terminalProfile: profile,
            destination: host.destination, port: host.port, identityFile: host.identityFile,
            sshOptions: options, localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: configuredCommand,
            agentSocketPath: params["ssh_auth_sock"] as? String, preserveAfterTerminalExit: true
        )
        let connection = SSHTuiConnection(configuration: configuration)
        let provider = try coordinator.provider(connection: connection)
        do {
            _ = try await provider.links.connected(machineID: connection.id)
        } catch {
            let reason = CloudMachineLink.errorText(error)
            if RemoteTmuxSSHTransport.indicatesAuthRequired(reason) {
                return ["auth_required": true, "ssh_argv": connection.authenticationArguments,
                        "destination": host.destination]
            }
            throw error
        }
        try Task.checkCancellation()
        guard ManagedRemoteConnectionsPolicy.isEnabled else { throw CancellationError() }
        var creation = params
        creation.removeValue(forKey: "initial_command")
        creation["eager_load_terminal"] = false
        creation["focus"] = false
        let created = v2WorkspaceCreate(params: creation)
        guard case .ok(let raw) = created,
              let payload = raw as? [String: Any],
              let rawID = payload["workspace_id"] as? String,
              let id = UUID(uuidString: rawID),
              let workspace = Workspace.liveWorkspace(id: id) else {
            throw CloudDiagnosticFailure.response
        }
        do {
            let initialCommand = (params["initial_command"] as? String).map(connection.commandArguments)
            try await coordinator.open(workspace: workspace, configuration: configuration, initialCommand: initialCommand)
            if params["focus"] as? Bool != false, let panelID = workspace.focusedPanelId {
                SurfacePaneFactory.focus(panelID: panelID, in: id)
            }
            var result = payload
            result["transport"] = "cmux-tui"
            result["carrier"] = "ssh"
            result["machine"] = connection.id
            result["remote"] = workspace.remoteStatusPayload()
            result["surface_id"] = workspace.focusedPanelId?.uuidString
            return result
        } catch {
            workspace.applyRemoteConnectionStateUpdate(.error, detail: CloudMachineLink.errorText(error), target: host.destination)
            throw error
        }
    }
}
