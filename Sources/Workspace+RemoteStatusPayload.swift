import CmuxCore
import Foundation

/// `workspace.remote.status` payload: connection/daemon state, daemon-signal
/// health (`daemon_health`), direct-vs-proxied `mode`, ports, proxy endpoint,
/// and heartbeat telemetry. Extracted from Workspace.swift; keep key names
/// stable — they are CLI/socket wire format.
extension Workspace {
    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        let daemonHealth = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: remoteConnectionState,
            daemon: remoteDaemonStatus,
            clientDaemonVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            ptySessionCount: activeRemoteTerminalSessionCount,
            lastSeenAt: remoteLastHeartbeatAt
        )
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "daemon_health": daemonHealth.payload(),
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
        if let remoteConfiguration {
            payload["transport"] = remoteConfiguration.transport.rawValue
            payload["mode"] = WorkspaceRemoteConnectionMode(transport: remoteConfiguration.transport).rawValue
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
            payload["persistent_daemon_slot"] = remoteConfiguration.persistentDaemonSlot ?? NSNull()
            payload["managed_cloud_vm_id"] = remoteConfiguration.managedCloudVMID ?? NSNull()
        } else {
            payload["transport"] = NSNull()
            payload["mode"] = NSNull()
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
            payload["persistent_daemon_slot"] = NSNull()
        }
        return payload
    }
}
