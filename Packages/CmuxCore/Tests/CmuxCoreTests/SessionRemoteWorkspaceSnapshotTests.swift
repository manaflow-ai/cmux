import Foundation
import Testing
@testable import CmuxCore

@Suite("SessionRemoteWorkspaceSnapshot persistence shape")
struct SessionRemoteWorkspaceSnapshotTests {
    @Test("codable round trip preserves every field")
    func codableRoundTrip() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "user@host",
            port: 2222,
            identityFile: "/id",
            sshOptions: ["ForwardAgent=yes"],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true,
            relayPort: 7000,
            persistentDaemonSlot: "slot",
            remoteMacTunnel: WorkspaceRemoteMacTunnel(
                attachURL: "cmux-ios://attach?v=1&payload=test",
                localEndpoint: "127.0.0.1:49321",
                forwardTarget: "100.102.73.120:61848",
                remoteWindowID: "33333333-3333-3333-3333-333333333333"
            )
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("decodes the persisted wire keys, optional fields absent")
    func decodesLegacyWireShape() throws {
        let json = """
        {
          "transport": "ssh",
          "destination": "user@host",
          "sshOptions": []
        }
        """
        let decoded = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self,
            from: Data(json.utf8)
        )
        #expect(decoded.transport == .ssh)
        #expect(decoded.destination == "user@host")
        #expect(decoded.port == nil)
        #expect(decoded.identityFile == nil)
        #expect(decoded.preserveAfterTerminalExit == nil)
        #expect(decoded.skipDaemonBootstrap == nil)
        #expect(decoded.relayPort == nil)
        #expect(decoded.persistentDaemonSlot == nil)
        #expect(decoded.remoteMacTunnel == nil)
    }

    @Test("transport raw values are the persisted wire strings")
    func transportRawValues() {
        #expect(WorkspaceRemoteTransport.ssh.rawValue == "ssh")
        #expect(WorkspaceRemoteTransport.websocket.rawValue == "websocket")
    }
}
