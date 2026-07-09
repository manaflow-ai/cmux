import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteDaemonProxyTunnel PTY bridge ownership")
struct RemoteDaemonProxyTunnelPTYBridgeTests {
    @Test("invalidation removes only matching session records and counts duplicate attachments")
    func invalidationSnapshotsMatchingBridgeRecords() {
        let tunnel = RemoteDaemonProxyTunnel(
            configuration: WorkspaceRemoteConfiguration(
                destination: "user@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: nil
            ),
            remotePath: "/remote/cmuxd",
            localPort: 42_424,
            strings: .init(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            ptyBridgeStrings: TestPTYBridgeStrings(),
            onFatalError: { _ in }
        )
        let records = [
            RemotePTYBridgeServerRecord(
                server: makeServer(sessionID: "target", attachmentID: "surface-a"),
                sessionID: "target",
                attachmentID: "surface-a"
            ),
            RemotePTYBridgeServerRecord(
                server: makeServer(sessionID: "target", attachmentID: "surface-a"),
                sessionID: "target",
                attachmentID: "surface-a"
            ),
            RemotePTYBridgeServerRecord(
                server: makeServer(sessionID: "other", attachmentID: "surface-b"),
                sessionID: "other",
                attachmentID: "surface-b"
            ),
        ]
        tunnel.queue.sync {
            for record in records {
                tunnel.ptyBridgeServers[UUID()] = record
            }
        }

        let counts = tunnel.invalidatePTYBridges(sessionID: "target")

        #expect(counts == ["surface-a": 2])
        #expect(tunnel.queue.sync { tunnel.ptyBridgeServers.values.map(\.sessionID) } == ["other"])
        tunnel.stop()
    }

    private func makeServer(sessionID: String, attachmentID: String) -> RemotePTYBridgeServer {
        RemotePTYBridgeServer(
            rpcClient: RecordingPTYBridgeRPCClient(),
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: nil,
            requireExisting: true,
            strings: TestPTYBridgeStrings(),
            onStop: {}
        )
    }
}
