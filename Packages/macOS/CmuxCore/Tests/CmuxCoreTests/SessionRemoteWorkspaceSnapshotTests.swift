import CmuxFoundation
import Foundation
import Testing
@testable import CmuxCore

@Suite("SessionRemoteWorkspaceSnapshot persistence shape")
struct SessionRemoteWorkspaceSnapshotTests {
    @Test("codable round trip preserves every field")
    func codableRoundTrip() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            terminalTransport: .mosh,
            terminalProfile: .defaultTmux,
            configuredRemoteCommand: "exec fish",
            destination: "user@host",
            port: 2222,
            identityFile: "/id",
            sshOptions: ["ForwardAgent=yes"],
            agentSocketPath: "/tmp/agent.sock",
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
        #expect(decoded.terminalTransport == nil)
        #expect(decoded.terminalProfile == nil)
        #expect(decoded.configuredRemoteCommand == nil)
        #expect(decoded.destination == "user@host")
        #expect(decoded.port == nil)
        #expect(decoded.identityFile == nil)
        #expect(decoded.agentSocketPath == nil)
        #expect(decoded.preserveAfterTerminalExit == nil)
        #expect(decoded.skipDaemonBootstrap == nil)
        #expect(decoded.relayPort == nil)
        #expect(decoded.persistentDaemonSlot == nil)
        #expect(decoded.managedCloudVMID == nil)
    }

    @Test("a cmux-tui SSH snapshot keeps only a cmux-owned ControlPath")
    func carrierSnapshotKeepsCmuxOwnedControlPath() throws {
        let directory = try #require(SSHConnectionSharingOptions().controlSocketDirectoryPath)
        let owned = directory + "/" + String(repeating: "b", count: 40)
        #expect(WorkspaceRemoteConfiguration.restorableCarrierSSHOptions(
            ["ProxyJump=bastion", "ControlMaster=auto", "ControlPersist=600", "ControlPath=\(owned)"]
        ) == ["ProxyJump=bastion", "ControlPath=\(owned)"])
        #expect(WorkspaceRemoteConfiguration.restorableCarrierSSHOptions(
            ["ControlMaster=auto", "ControlPath=/tmp/shared-%C"]
        ) == [])
        #expect(WorkspaceRemoteConfiguration.restorableCarrierSSHOptions(
            ["ControlMaster=no", "ControlPath=\(owned)"]
        ) == [])
    }

    @Test("transport raw values are the persisted wire strings")
    func transportRawValues() {
        #expect(WorkspaceRemoteTransport.ssh.rawValue == "ssh")
        #expect(WorkspaceRemoteTransport.websocket.rawValue == "websocket")
        #expect(WorkspaceRemoteTerminalTransport.ssh.rawValue == "ssh")
        #expect(WorkspaceRemoteTerminalTransport.mosh.rawValue == "mosh")
        #expect(WorkspaceRemoteTerminalProfile.Kind.tmux.rawValue == "tmux")
    }
}
