import Foundation
import Testing
@testable import CmuxCore

@Suite("WorkspaceRemoteDaemonHealth")
struct WorkspaceRemoteDaemonHealthTests {
    private func ready(version: String?) -> WorkspaceRemoteDaemonStatus {
        WorkspaceRemoteDaemonStatus(state: .ready, version: version, name: "cmuxd-remote")
    }

    @Test("connected + ready + matching versions is running")
    func running() {
        let health = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .connected,
            daemon: ready(version: "0.99.0"),
            clientDaemonVersion: "0.99.0",
            ptySessionCount: 2,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(health.state == .running)
        #expect(!health.needsUpgrade)
        #expect(health.ptySessionCount == 2)
    }

    @Test("connected + ready + older daemon needs upgrade")
    func needsUpgrade() {
        let health = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .connected,
            daemon: ready(version: "0.98.0"),
            clientDaemonVersion: "0.99.0",
            ptySessionCount: 0,
            lastSeenAt: nil
        )
        #expect(health.state == .needsUpgrade)
        #expect(health.needsUpgrade)
        #expect(health.daemonVersion == "0.98.0")
        #expect(health.clientVersion == "0.99.0")
    }

    @Test("dev fingerprint versions never count as drift")
    func devVersionsNoDrift() {
        #expect(!WorkspaceRemoteDaemonHealth.versionDrift(
            daemonVersion: "0.99.0-dev-abc123",
            clientVersion: "0.99.0"
        ))
        #expect(!WorkspaceRemoteDaemonHealth.versionDrift(daemonVersion: nil, clientVersion: "0.99.0"))
        #expect(WorkspaceRemoteDaemonHealth.versionDrift(daemonVersion: "0.98.0", clientVersion: "0.99.0"))
    }

    @Test("suspended transport is unreachable regardless of last daemon state")
    func suspendedUnreachable() {
        let health = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .suspended,
            daemon: ready(version: "0.99.0"),
            clientDaemonVersion: "0.99.0",
            ptySessionCount: 1,
            lastSeenAt: nil
        )
        #expect(health.state == .unreachable)
    }

    @Test("bootstrapping or reconnecting is degraded")
    func degradedStates() {
        let bootstrapping = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .connected,
            daemon: WorkspaceRemoteDaemonStatus(state: .bootstrapping),
            clientDaemonVersion: "0.99.0",
            ptySessionCount: 0,
            lastSeenAt: nil
        )
        #expect(bootstrapping.state == .degraded)

        let reconnecting = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .reconnecting,
            daemon: ready(version: "0.99.0"),
            clientDaemonVersion: "0.99.0",
            ptySessionCount: 0,
            lastSeenAt: nil
        )
        #expect(reconnecting.state == .degraded)
    }

    @Test("disconnected is unknown")
    func disconnectedUnknown() {
        let health = WorkspaceRemoteDaemonHealth.evaluate(
            connectionState: .disconnected,
            daemon: WorkspaceRemoteDaemonStatus(),
            clientDaemonVersion: nil,
            ptySessionCount: 0,
            lastSeenAt: nil
        )
        #expect(health.state == .unknown)
    }

    @Test("payload carries wire keys and heartbeat age")
    func payloadShape() {
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let health = WorkspaceRemoteDaemonHealth(
            state: .running,
            daemonVersion: "0.99.0",
            clientVersion: "0.99.0",
            needsUpgrade: false,
            ptySessionCount: 3,
            lastSeenAt: seen
        )
        let payload = health.payload(now: seen.addingTimeInterval(12))
        #expect(payload["state"] as? String == "running")
        #expect(payload["needs_upgrade"] as? Bool == false)
        #expect(payload["pty_sessions"] as? Int == 3)
        #expect(payload["last_seen_age_seconds"] as? TimeInterval == 12)
    }

    @Test("connection mode maps ssh to direct and websocket to cloud-proxied")
    func connectionMode() {
        #expect(WorkspaceRemoteConnectionMode(transport: .ssh) == .direct)
        #expect(WorkspaceRemoteConnectionMode(transport: .websocket) == .cloudProxied)
        #expect(WorkspaceRemoteConnectionMode.cloudProxied.rawValue == "cloud_proxied")
    }
}
