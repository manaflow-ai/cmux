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
            scope: .pane,
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true,
            relayPort: 7000,
            persistentDaemonSlot: "slot",
            managedCloudVMID: "vm-123"
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
        #expect(decoded.scope == nil)
        #expect(decoded.preserveAfterTerminalExit == nil)
        #expect(decoded.skipDaemonBootstrap == nil)
        #expect(decoded.relayPort == nil)
        #expect(decoded.persistentDaemonSlot == nil)
        #expect(decoded.managedCloudVMID == nil)
    }

    @Test("transport raw values are the persisted wire strings")
    func transportRawValues() {
        #expect(WorkspaceRemoteTransport.ssh.rawValue == "ssh")
        #expect(WorkspaceRemoteTransport.websocket.rawValue == "websocket")
    }

    @Test("pane scope round-trips through sessionSnapshot")
    func paneScopeRoundTripThroughConfigurationSnapshot() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@host",
            port: 2222,
            identityFile: nil,
            scope: .pane,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh user@host"
        )
        let snapshot = try #require(configuration.sessionSnapshot())
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: data)
        #expect(decoded.scope == .pane)
    }

    @Test("workspace scope is omitted from encoded sessionSnapshot")
    func workspaceScopeIsOmittedFromConfigurationSnapshot() throws {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "ssh user@host"
        )
        let snapshot = try #require(configuration.sessionSnapshot())
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["scope"] == nil)
        let decoded = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: data)
        #expect(decoded.scope == nil)
    }
}
