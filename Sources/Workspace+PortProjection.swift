import CmuxSettings
import Foundation

/// Port presentation and remote status derived from authoritative workspace state.
extension Workspace {
    func recomputeListeningPorts() {
        let policy = currentSidebarPortVisibilityPolicy()
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let authoritativePorts = unique.sorted()
        if listeningPorts != authoritativePorts {
            listeningPorts = authoritativePorts
        }
        // Keep authoritative observations independent from the sidebar
        // projection so control APIs and automation never lose hidden badges.
        setSidebarVisibleListeningPorts(policy.visiblePorts(from: authoritativePorts))
    }

    /// Whether remote listening-port discovery may run, derived from the global
    /// sidebar ports-visibility settings. Mirrors the sidebar's own precedence
    /// (`sidebar.hideAllDetails` wins over `sidebar.showPorts`, see
    /// `SidebarWorkspaceAuxiliaryDetailVisibility.resolved`): when the ports
    /// detail is not displayed there is nothing for the remote scans to
    /// populate, so the backend ssh port-scan loop is suspended (issue #6123).
    static func remotePortScanningEnabledFromSettings(defaults: UserDefaults = .standard) -> Bool {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let showsPorts = settings.value(for: catalog.sidebar.showPorts)
        let hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        return showsPorts && !hidesAllDetails
    }

    /// Pushes the current remote port-scanning enablement to this workspace's
    /// active remote session, if any. No-op for non-remote workspaces.
    func applyRemotePortScanningEnabled(_ enabled: Bool) {
        remoteSessionController?.updateRemotePortScanningEnabled(enabled)
    }

    func listRemotePTYSessions() throws -> [[String: Any]] {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.listPTYSessions()
    }

    func closeRemotePTYSession(sessionID: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.closePTYSession(sessionID: sessionID)
    }

    func resizeRemotePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    func detachRemotePTYAttachment(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        guard let controller = remoteSessionController else {
            throw NSError(domain: "cmux.remote.pty", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func makeRemoteStatusPayload(
        heartbeatTimestamp: Any,
        hasProxyOnlyRemoteSidebarError: Bool
    ) -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting, .reconnecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        payload["transport"] = (remoteConfiguration?.transport.rawValue as Any?) ?? NSNull()
        payload["terminal_transport"] = (remoteConfiguration?.terminalTransport.rawValue as Any?) ?? NSNull()
        payload["terminal_profile"] = (remoteConfiguration?.terminalProfile.kind.rawValue as Any?) ?? NSNull()
        payload["terminal_tmux_session"] = (remoteConfiguration?.terminalProfile.tmuxSessionName as Any?) ?? NSNull()
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
            payload["persistent_daemon_slot"] = remoteConfiguration.persistentDaemonSlot ?? NSNull()
            payload["managed_cloud_vm_id"] = remoteConfiguration.managedCloudVMID ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
            payload["persistent_daemon_slot"] = NSNull()
        }
        // A cmux-tui workspace reports its machine under the same key the managed
        // transports use, so `cmux vm desktop`/the Machines panel find it either way.
        if let binding = cloudVMBinding {
            if remoteConfiguration?.managedCloudVMID?.isEmpty != false {
                payload["managed_cloud_vm_id"] = binding.vmID
            }
            payload["cloud_vm_id"] = binding.vmID
            payload["cloud_vm_base"] = binding.isBase
            payload["cloud_vm_transport"] = "cmux-remote"
        } else {
            payload["cloud_vm_id"] = NSNull()
            payload["cloud_vm_base"] = NSNull()
            payload["cloud_vm_transport"] = NSNull()
        }
        return payload
    }

}
