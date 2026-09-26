import CmuxCloud
import CmuxCore
import CmuxFoundation
import CmuxSurfaceCatalogModel
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
            sshOptions: options, sshKeepaliveSettings: CmuxConfigStore.loadGlobalSSHKeepaliveSettings(),
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: configuredCommand,
            agentSocketPath: params["ssh_auth_sock"] as? String, preserveAfterTerminalExit: true
        )
        let connection = SSHTuiConnection(configuration: configuration)
        let provider = try coordinator.provider(connection: connection)
        guard let links = provider.links as? SSHTuiLinkManager else { throw CloudDiagnosticFailure.unsupported }
        do {
            // Like `ssh`, a new route reports OpenSSH's own failure in seconds
            // instead of waiting out the headless carrier's retries.
            _ = try await links.connected(machineID: connection.id, preflight: true)
        } catch let error where Self.sshTuiNeedsInteractiveLogin(error) {
            return ["auth_required": true, "ssh_argv": connection.authenticationArguments,
                    "destination": host.destination]
        } catch {
            throw Self.sshTuiOpenFailure(error)
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
            throw Self.sshTuiOpenFailure(error)
        }
    }

    /// Whether an interactive `ssh` can clear an open's failure. Only the
    /// prompt-free login decides this: carrier output after it passed can
    /// quote a remote "Permission denied" that no login fixes.
    static func sshTuiNeedsInteractiveLogin(_ error: Error) -> Bool {
        guard let failure = error as? SSHTuiPreflightError else { return false }
        return failure.stalledBeforeAuthentication
            || RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(failure.standardError)
    }

    /// OpenSSH and carrier output belongs to the user's own SSH route, so it
    /// keeps its text instead of the Cloud VM fallback that hides provider detail.
    private static func sshTuiOpenFailure(_ error: Error) -> Error {
        guard error is SSHTuiPreflightError || error is CloudMachineLink.LinkError else { return error }
        return SSHTuiOpenFailure(reason: CloudMachineLink.errorText(error))
    }
}

/// An SSH route failure reported to the caller with OpenSSH's diagnostic.
struct SSHTuiOpenFailure: Error {
    let reason: String
}
