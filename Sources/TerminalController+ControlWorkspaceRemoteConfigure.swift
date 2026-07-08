import CmuxControlSocket
import CmuxCore
import Foundation

extension TerminalController {
    func controlConfigureWorkspaceRemote(
        params typedParams: [String: JSONValue],
        workspaceID workspaceId: UUID
    ) -> ControlCallResult {
        // The configure body validates ~40 params against the app's
        // `WorkspaceRemote*` types, so it stays app-side. Bridge the typed params
        // back to the `[String: Any]` shape the legacy `v2*` param helpers expect
        // so the acceptance is byte-identical.
        let params: [String: Any] = typedParams.mapValues(\.foundationObject)

        guard let destination = v2String(params, "destination") else {
            return .err(code: "invalid_params", message: "Missing destination", data: nil)
        }

        var sshPort: Int?
        if v2HasNonNullParam(params, "port") {
            guard let parsedPort = v2StrictInt(params, "port"),
                  parsedPort > 0,
                  parsedPort <= 65535 else {
                return .err(code: "invalid_params", message: "port must be 1-65535", data: nil)
            }
            sshPort = parsedPort
        }

        var localProxyPort: Int?
        if v2HasNonNullParam(params, "local_proxy_port") {
            guard let parsedLocalProxyPort = v2StrictInt(params, "local_proxy_port"),
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .err(code: "invalid_params", message: "local_proxy_port must be 1-65535", data: nil)
            }
            localProxyPort = parsedLocalProxyPort
        }

        let scope: WorkspaceRemoteScope
        if v2HasNonNullParam(params, "scope") {
            let scopeRaw = v2RawString(params, "scope")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let scopeRaw,
                  let parsedScope = WorkspaceRemoteScope(rawValue: scopeRaw) else {
                return .err(code: "invalid_params", message: "scope must be workspace or pane", data: nil)
            }
            scope = parsedScope
        } else {
            scope = .workspace
        }
        let seedSurfaceId: UUID?
        if v2HasNonNullParam(params, "seed_surface_id") {
            guard let parsedSeedSurfaceId = v2UUID(params, "seed_surface_id") else {
                return .err(code: "invalid_params", message: "seed_surface_id must be a UUID", data: nil)
            }
            seedSurfaceId = parsedSeedSurfaceId
        } else {
            seedSurfaceId = nil
        }
        if scope == .pane, seedSurfaceId == nil {
            return .err(code: "invalid_params", message: "seed_surface_id is required when scope is pane", data: nil)
        }

        let identityFile = v2RawString(params, "identity_file")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshOptions = v2StringArray(params, "ssh_options") ?? []
        let transportRaw = v2RawString(params, "transport")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let transport = WorkspaceRemoteTransport(rawValue: transportRaw ?? "") ?? .ssh
        let autoConnect = v2Bool(params, "auto_connect") ?? true
        var relayPort: Int?
        if v2HasNonNullParam(params, "relay_port") {
            guard let parsedRelayPort = v2StrictInt(params, "relay_port"),
                  parsedRelayPort > 0,
                  parsedRelayPort <= 65535 else {
                return .err(code: "invalid_params", message: "relay_port must be 1-65535", data: nil)
            }
            relayPort = parsedRelayPort
        }
        let relayID = v2RawString(params, "relay_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayToken = v2RawString(params, "relay_token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let foregroundAuthToken = v2RawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localSocketPath = v2RawString(params, "local_socket_path")
        let hasExplicitAgentSocketPath = v2HasNonNullParam(params, "ssh_auth_sock")
        let agentSocketPath = v2RawString(params, "ssh_auth_sock")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalStartupCommand = v2RawString(params, "terminal_startup_command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let managedCloudVMID = v2RawString(params, "managed_cloud_vm_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var persistentDaemonSlot = v2RawString(params, "persistent_daemon_slot")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if v2HasNonNullParam(params, "persistent_daemon_slot") {
            guard let persistentDaemonSlot,
                  !persistentDaemonSlot.isEmpty,
                  persistentDaemonSlot.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  persistentDaemonSlot != ".",
                  persistentDaemonSlot != ".." else {
                return .err(
                    code: "invalid_params",
                    message: "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'",
                    data: nil
                )
            }
        }
        let daemonWebSocketURL = v2RawString(params, "daemon_websocket_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketToken = v2RawString(params, "daemon_websocket_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketSessionID = v2RawString(params, "daemon_websocket_session_id")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonWebSocketExpiresAtUnix = (params["daemon_websocket_expires_at_unix"] as? Int64)
            ?? Int64((params["daemon_websocket_expires_at_unix"] as? Double) ?? 0)
        let rawDaemonHeaders = params["daemon_websocket_headers"] as? [String: Any] ?? [:]
        let daemonWebSocketHeaders = rawDaemonHeaders.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            }
        }
        let daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint?
        if let daemonWebSocketURL,
           !daemonWebSocketURL.isEmpty,
           let daemonWebSocketToken,
           !daemonWebSocketToken.isEmpty,
           let daemonWebSocketSessionID,
           !daemonWebSocketSessionID.isEmpty {
            daemonWebSocketEndpoint = WorkspaceRemoteWebSocketDaemonEndpoint(
                url: daemonWebSocketURL,
                headers: daemonWebSocketHeaders,
                token: daemonWebSocketToken,
                sessionId: daemonWebSocketSessionID,
                expiresAtUnix: daemonWebSocketExpiresAtUnix
            )
        } else {
            daemonWebSocketEndpoint = nil
        }
        let preserveAfterTerminalExit = v2Bool(params, "preserve_after_terminal_exit") ?? false
        if v2HasNonNullParam(params, "preserve_after_terminal_exit"),
           v2Bool(params, "preserve_after_terminal_exit") == nil {
            return .err(
                code: "invalid_params",
                message: "preserve_after_terminal_exit must be a boolean",
                data: nil
            )
        }
        let skipDaemonBootstrap = v2Bool(params, "skip_daemon_bootstrap") ?? false
        if persistentDaemonSlot != nil, !preserveAfterTerminalExit {
            return .err(
                code: "invalid_params",
                message: "preserve_after_terminal_exit is required when persistent_daemon_slot is set",
                data: nil
            )
        }
        if preserveAfterTerminalExit,
           transport == .ssh,
           !skipDaemonBootstrap,
           daemonWebSocketEndpoint == nil,
           persistentDaemonSlot == nil {
            persistentDaemonSlot = "ssh-\(workspaceId.uuidString.lowercased())"
        }
        if relayPort != nil {
            guard let relayID, !relayID.isEmpty else {
                return .err(code: "invalid_params", message: "relay_id is required when relay_port is set", data: nil)
            }
            guard let relayToken,
                  relayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return .err(code: "invalid_params", message: "relay_token must be 64 lowercase hex characters when relay_port is set", data: nil)
            }
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.remote.configure.request workspace=\(workspaceId.uuidString.prefix(8)) " +
            "target=\(destination) transport=\(transport.rawValue) port=\(sshPort.map(String.init) ?? "nil") " +
            "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(localSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? localSocketPath! : "nil") " +
            "sshAuthSock=\(agentSocketPath?.isEmpty == false ? 1 : 0) " +
            "sshOptions=\(sshOptions.joined(separator: "|")) scope=\(scope.rawValue)"
        )
#endif

        guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
            return .err(code: "not_found", message: "Workspace not found", data: .object([
                "workspace_id": .string(workspaceId.uuidString),
                "workspace_ref": controlWorkspaceRefValue(workspaceId),
            ]))
        }
        if let seedSurfaceId, workspace.terminalPanel(for: seedSurfaceId) == nil {
            return .err(code: "not_found", message: "Seed surface not found", data: .object([
                "workspace_id": .string(workspace.id.uuidString),
                "workspace_ref": controlWorkspaceRefValue(workspace.id),
                "seed_surface_id": .string(seedSurfaceId.uuidString),
                "seed_surface_ref": .string(controlCommandCoordinator.ensureRef(kind: .surface, uuid: seedSurfaceId)),
            ]))
        }

        let config = WorkspaceRemoteConfiguration(
            transport: transport,
            destination: destination,
            port: sshPort,
            identityFile: identityFile?.isEmpty == true ? nil : identityFile,
            scope: scope,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID?.isEmpty == true ? nil : relayID,
            relayToken: relayToken?.isEmpty == true ? nil : relayToken,
            localSocketPath: localSocketPath,
            managedCloudVMID: managedCloudVMID?.isEmpty == true ? nil : managedCloudVMID,
            terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand,
            foregroundAuthToken: foregroundAuthToken?.isEmpty == true ? nil : foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: sshOptions,
                explicitAgentSocketPath: agentSocketPath,
                explicitAgentSocketPathIsSet: hasExplicitAgentSocketPath
            ),
            daemonWebSocketEndpoint: daemonWebSocketEndpoint,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot?.isEmpty == true ? nil : persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )

        let windowId = AppDelegate.shared?.windowId(for: owner)
        func okPayload(joinedExisting: Bool? = nil, startupCommand: String? = nil) -> ControlCallResult {
            var payload: [String: JSONValue] = [
                "window_id": controlWindowOrNull(windowId),
                "window_ref": controlWindowRefValue(windowId),
                "workspace_id": .string(workspace.id.uuidString),
                "workspace_ref": controlWorkspaceRefValue(workspace.id),
                "remote": JSONValue(foundationObject: workspace.remoteStatusPayload()) ?? .object([:]),
            ]
            if let joinedExisting {
                payload["joined_existing"] = .bool(joinedExisting)
            }
            if let startupCommand {
                payload["startup_command"] = .string(startupCommand)
            }
            return .ok(.object(payload))
        }

        func invalidState(_ message: String, existingTarget: String? = nil) -> ControlCallResult {
            var data: [String: JSONValue] = [
                "workspace_id": .string(workspace.id.uuidString),
                "workspace_ref": controlWorkspaceRefValue(workspace.id),
                "destination": .string(config.displayTarget),
            ]
            if let existingTarget {
                data["existing_destination"] = .string(existingTarget)
            }
            return .err(code: "invalid_state", message: message, data: .object(data))
        }

        if scope == .pane, let existing = workspace.remoteConfiguration {
            if existing.scope == .workspace {
                return invalidState(
                    "Workspace is already a remote workspace (\(existing.displayTarget)); disconnect it before attaching a pane.",
                    existingTarget: existing.displayTarget
                )
            }
            if existing.hasSamePaneScopeTarget(as: config) {
                guard let seedSurfaceId,
                      let startupCommand = workspace.joinPaneScopedRemoteConnection(seedPanelId: seedSurfaceId) else {
                    return invalidState(
                        "Workspace has a pane-scoped SSH connection but the seed pane could not join it.",
                        existingTarget: existing.displayTarget
                    )
                }
                notifyRemotePTYControllerAvailabilityChanged()
                return okPayload(joinedExisting: true, startupCommand: startupCommand)
            }
            return invalidState(
                "Workspace already has a pane-scoped SSH connection to \(existing.displayTarget); use a different workspace for \(config.displayTarget).",
                existingTarget: existing.displayTarget
            )
        }
        if scope == .workspace,
           let existing = workspace.remoteConfiguration,
           existing.scope == .pane {
            return invalidState(
                "Workspace has a pane-scoped SSH connection; disconnect it first.",
                existingTarget: existing.displayTarget
            )
        }

        workspace.configureRemoteConnection(config, autoConnect: autoConnect, seedPanelId: seedSurfaceId)
        notifyRemotePTYControllerAvailabilityChanged()
        return okPayload()
    }
}
