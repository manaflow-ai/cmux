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
        if params["here"] != nil, !(params["here"] is Bool) {
            throw CloudDiagnosticFailure.unsupported
        }
        let callerProcess: AgentPIDProcessIdentity?
        var callerObservation: AgentRestoreEvidenceSubscription?
        var callerObservationAdopted = false
        defer { if !callerObservationAdopted { callerObservation?.cancel() } }
        let hereTarget: (workspace: Workspace, panel: TerminalPanel)?
        if params["here"] as? Bool == true {
            let identity = try SSHTuiHereSession.callerProcess(from: params["caller_process"])
            try SSHTuiHereSession.requireLiveCaller(identity)
            callerProcess = identity
            // Construction arms and resumes the kernel source. Check again
            // afterwards so an exit during registration cannot be missed.
            callerObservation = AgentRestoreEvidenceSubscription(process: identity, paths: [], deadline: .distantFuture)
            try SSHTuiHereSession.requireLiveCaller(identity)
            guard let workspaceID = v2UUID(params, "workspace_id"),
                  let panelID = v2UUID(params, "surface_id"),
                  let workspace = Workspace.liveWorkspace(id: workspaceID),
                  workspace.canBeginSSHTuiHereSession(panelID: panelID),
                  let panel = workspace.terminalPanel(for: panelID) else {
                throw SurfaceCatalogError.unsupported(String(
                    localized: "cli.ssh.here.requiresSingleLocalPane",
                    defaultValue: "ssh --here requires a workspace with one local terminal pane and no remote connection."
                ))
            }
            hereTarget = (workspace, panel)
        } else {
            hereTarget = nil
            callerProcess = nil
            callerObservation = nil
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
        guard let links = provider.links as? SSHTuiLinkManager else { throw CloudDiagnosticFailure.unsupported }
        await links.adopt(connection)
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
        let shouldFocus = params["focus"] as? Bool != false
        let workspace: Workspace
        let payload: [String: Any]
        let hereSession: SSHTuiHereSession?
        if let target = hereTarget {
            if let callerProcess { try SSHTuiHereSession.requireLiveCaller(callerProcess) }
            guard target.workspace.terminalPanel(for: target.panel.id) === target.panel,
                  target.workspace.canBeginSSHTuiHereSession(panelID: target.panel.id) else {
                throw CloudDiagnosticFailure.placement
            }
            workspace = target.workspace
            let session = try workspace.beginSSHTuiHereSession(
                panelID: target.panel.id, machine: provider.machine,
                operationID: (params["operation_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            )
            hereSession = session
            if let title = (params["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                session.requestedTitle = title
                if let manager = workspace.owningTabManager {
                    manager.setCustomTitle(tabId: workspace.id, title: title)
                } else {
                    workspace.setCustomTitle(title)
                }
            }
            let windowID = workspace.owningTabManager.flatMap { AppDelegate.shared?.windowId(for: $0) }
            payload = [
                "window_id": v2OrNull(windowID?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowID),
                "workspace_id": workspace.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "group_id": v2OrNull(workspace.groupId?.uuidString), "group_ref": v2Ref(kind: .workspaceGroup, uuid: workspace.groupId),
                "pane_id": session.paneID.id.uuidString, "pane_ref": v2Ref(kind: .pane, uuid: session.paneID.id),
            ]
        } else {
            var creation = params
            creation.removeValue(forKey: "initial_command")
            creation["eager_load_terminal"] = false
            creation["focus"] = shouldFocus
            let created = v2WorkspaceCreate(params: creation)
            guard case .ok(let raw) = created,
                  let createdPayload = raw as? [String: Any],
                  let rawID = createdPayload["workspace_id"] as? String,
                  let id = UUID(uuidString: rawID),
                  let createdWorkspace = Workspace.liveWorkspace(id: id) else {
                throw CloudDiagnosticFailure.response
            }
            workspace = createdWorkspace
            payload = createdPayload
            hereSession = nil
        }
        do {
            if let hereSession, let callerProcess, let callerObservation {
                try hereSession.observeCallerProcess(callerProcess, subscription: callerObservation, in: workspace)
                callerObservationAdopted = true
            }
            let initialCommand = (params["initial_command"] as? String).map(connection.commandArguments)
            try await coordinator.open(workspace: workspace, configuration: configuration, initialCommand: initialCommand,
                                       focus: shouldFocus, expectedHereSession: hereSession)
            let surfaceID = hereSession?.reservation.panelID ?? workspace.focusedPanelId
            if shouldFocus, let panelID = surfaceID {
                if let manager = AppDelegate.shared?.tabManagerFor(tabId: workspace.id) {
                    manager.selectWorkspace(workspace)
                }
                SurfacePaneFactory.focus(panelID: panelID, in: workspace.id)
            }
            var result = payload
            result["transport"] = "cmux-tui"
            result["carrier"] = "ssh"
            result["machine"] = connection.id
            result["remote"] = workspace.remoteStatusPayload()
            result["surface_id"] = surfaceID?.uuidString
            result["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceID)
            if let hereSession { result["here_operation_id"] = hereSession.operationID.uuidString.lowercased() }
            return result
        } catch {
            if let hereSession {
                if workspace.sshTuiHereSession === hereSession {
                    workspace.finishSSHTuiHereSession(rollback: true)
                }
            } else {
                workspace.applyRemoteConnectionStateUpdate(.error, detail: CloudMachineLink.errorText(error), target: host.destination)
            }
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
