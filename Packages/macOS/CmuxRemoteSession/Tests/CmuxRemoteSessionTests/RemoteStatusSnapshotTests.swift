import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteSession

// Pins the byte-faithful wire shape of the `remote` status payload lifted out
// of `Workspace.remoteStatusPayload()`. Keys, NSNull placeholders, the derived
// proxy-state string, and the ISO-8601 heartbeat timestamp are protocol output.
@Suite("Remote status snapshot payload")
struct RemoteStatusSnapshotTests {
    private static func sshConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: .ssh,
            destination: "user@host",
            port: 2222,
            identityFile: "/keys/id",
            sshOptions: ["StrictHostKeyChecking=no"],
            localProxyPort: 1080,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            persistentDaemonSlot: nil
        )
    }

    @Test("Local workspace (nil config) emits disabled placeholders")
    func localWorkspacePlaceholders() {
        let payload = RemoteStatusSnapshot(
            configuration: nil,
            connectionState: .disconnected,
            activeTerminalSessionCount: 0,
            daemonStatus: WorkspaceRemoteDaemonStatus(),
            detectedPorts: [],
            forwardedPorts: [],
            portConflicts: [],
            connectionDetail: nil,
            heartbeatCount: 0,
            lastHeartbeatAt: nil,
            proxyEndpoint: nil,
            hasProxyOnlySidebarError: false
        ).payload()

        #expect(payload["enabled"] as? Bool == false)
        #expect(payload["state"] as? String == "disconnected")
        #expect(payload["connected"] as? Bool == false)
        #expect(payload["transport"] is NSNull)
        #expect(payload["destination"] is NSNull)
        #expect(payload["has_identity_file"] as? Bool == false)
        #expect(payload["has_ssh_options"] as? Bool == false)
        #expect(payload["local_proxy_port"] is NSNull)
        #expect(payload["persistent_daemon_slot"] is NSNull)

        let proxy = payload["proxy"] as? [String: Any]
        #expect(proxy?["state"] as? String == "unavailable")
        #expect(proxy?["url"] is NSNull)
        #expect(proxy?["error_code"] is NSNull)

        let heartbeat = payload["heartbeat"] as? [String: Any]
        #expect(heartbeat?["count"] as? Int == 0)
        #expect(heartbeat?["last_seen_at"] is NSNull)
        #expect(heartbeat?["age_seconds"] is NSNull)
    }

    @Test("Connected with a ready proxy emits the ready proxy block + config")
    func connectedProxyBlock() {
        let lastSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = RemoteStatusSnapshot(
            configuration: Self.sshConfiguration(),
            connectionState: .connected,
            activeTerminalSessionCount: 2,
            daemonStatus: WorkspaceRemoteDaemonStatus(state: .ready, version: "v1"),
            detectedPorts: [3000, 8080],
            forwardedPorts: [3000],
            portConflicts: [],
            connectionDetail: "Connected",
            heartbeatCount: 5,
            lastHeartbeatAt: lastSeen,
            proxyEndpoint: BrowserProxyEndpoint(host: "127.0.0.1", port: 1080),
            hasProxyOnlySidebarError: false
        ).payload()

        #expect(payload["enabled"] as? Bool == true)
        #expect(payload["connected"] as? Bool == true)
        #expect(payload["active_terminal_sessions"] as? Int == 2)
        #expect(payload["transport"] as? String == "ssh")
        #expect(payload["destination"] as? String == "user@host")
        #expect(payload["port"] as? Int == 2222)
        #expect(payload["has_identity_file"] as? Bool == true)
        #expect(payload["has_ssh_options"] as? Bool == true)
        #expect(payload["local_proxy_port"] as? Int == 1080)
        #expect((payload["detected_ports"] as? [Int]) == [3000, 8080])
        #expect((payload["forwarded_ports"] as? [Int]) == [3000])

        let proxy = payload["proxy"] as? [String: Any]
        #expect(proxy?["state"] as? String == "ready")
        #expect(proxy?["host"] as? String == "127.0.0.1")
        #expect(proxy?["port"] as? Int == 1080)
        #expect(proxy?["url"] as? String == "socks5://127.0.0.1:1080")

        let heartbeat = payload["heartbeat"] as? [String: Any]
        #expect(heartbeat?["count"] as? Int == 5)
        #expect(heartbeat?["last_seen_at"] as? String == "2023-11-14T22:13:20.000Z")
        #expect((heartbeat?["age_seconds"] as? Double).map { $0 >= 0 } == true)

        // Daemon sub-object delegates to the daemon serializer's own owner.
        let daemon = payload["daemon"] as? [String: Any]
        #expect(daemon?["state"] as? String == WorkspaceRemoteDaemonState.ready.rawValue)
        #expect(daemon?["version"] as? String == "v1")
    }

    @Test("Proxy-only sidebar error forces an error proxy state with no proxy endpoint")
    func proxyOnlyErrorState() {
        let payload = RemoteStatusSnapshot(
            configuration: Self.sshConfiguration(),
            connectionState: .connected,
            activeTerminalSessionCount: 1,
            daemonStatus: WorkspaceRemoteDaemonStatus(state: .ready),
            detectedPorts: [],
            forwardedPorts: [],
            portConflicts: [],
            connectionDetail: nil,
            heartbeatCount: 0,
            lastHeartbeatAt: nil,
            proxyEndpoint: nil,
            hasProxyOnlySidebarError: true
        ).payload()

        let proxy = payload["proxy"] as? [String: Any]
        #expect(proxy?["state"] as? String == "error")
        #expect(proxy?["error_code"] as? String == "proxy_unavailable")
        #expect(proxy?["host"] is NSNull)
    }

    @Test("Connecting state maps to a connecting proxy state when no endpoint")
    func connectingProxyState() {
        let payload = RemoteStatusSnapshot(
            configuration: Self.sshConfiguration(),
            connectionState: .connecting,
            activeTerminalSessionCount: 0,
            daemonStatus: WorkspaceRemoteDaemonStatus(),
            detectedPorts: [],
            forwardedPorts: [],
            portConflicts: [],
            connectionDetail: nil,
            heartbeatCount: 0,
            lastHeartbeatAt: nil,
            proxyEndpoint: nil,
            hasProxyOnlySidebarError: false
        ).payload()

        let proxy = payload["proxy"] as? [String: Any]
        #expect(proxy?["state"] as? String == "connecting")
        #expect(proxy?["error_code"] is NSNull)
    }
}
