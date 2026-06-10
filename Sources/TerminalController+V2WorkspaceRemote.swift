import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 workspace remote configure/connect methods
extension TerminalController {
    func v2WorkspaceRemoteConfigure(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
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

        // Internal deterministic test hook: pin the local proxy listener port to force bind conflicts.
        var localProxyPort: Int?
        if v2HasNonNullParam(params, "local_proxy_port") {
            guard let parsedLocalProxyPort = v2StrictInt(params, "local_proxy_port"),
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .err(code: "invalid_params", message: "local_proxy_port must be 1-65535", data: nil)
            }
            localProxyPort = parsedLocalProxyPort
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
            "sshOptions=\(sshOptions.joined(separator: "|"))"
        )
#endif
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.configureRemoteConnection mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            let config = WorkspaceRemoteConfiguration(
                transport: transport,
                destination: destination,
                port: sshPort,
                identityFile: identityFile?.isEmpty == true ? nil : identityFile,
                sshOptions: sshOptions,
                localProxyPort: localProxyPort,
                relayPort: relayPort,
                relayID: relayID?.isEmpty == true ? nil : relayID,
                relayToken: relayToken?.isEmpty == true ? nil : relayToken,
                localSocketPath: localSocketPath,
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
            workspace.configureRemoteConnection(config, autoConnect: autoConnect)
            notifyRemotePTYControllerAvailabilityChanged()

            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteDisconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        let clearConfiguration = v2Bool(params, "clear") ?? false
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because disconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.disconnectRemoteConnection(clearConfiguration: clearConfiguration)
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteReconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because reconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            guard workspace.remoteConfiguration != nil else {
                result = .err(code: "invalid_state", message: "Remote workspace is not configured", data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                ])
                return
            }

            workspace.reconnectRemoteConnection()
            notifyRemotePTYControllerAvailabilityChanged()
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteForegroundAuthReady(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        let foregroundAuthToken = v2RawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because this may arm a pending connect or start reconnecting immediately.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.notifyRemoteForegroundAuthenticationReady(token: foregroundAuthToken)
            notifyRemotePTYControllerAvailabilityChanged()
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteStatus(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.remoteStatusPayload reads TabManager/UI-owned state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

}
