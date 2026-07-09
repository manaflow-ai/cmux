import CmuxCore
import Testing
@testable import CmuxRemoteSession

// Ported from the app-target WorkspaceRemoteConnectionTests control-master
// cleanup assertions when the `ssh -O exit` argv builder was lifted into
// CmuxRemoteSession. The argv is protocol-frozen: option order, the
// ControlMaster/ControlPersist stripping, and the case-insensitive key parse
// must stay byte-identical to the legacy `Workspace` statics.
@Suite("RemoteControlMasterCleanup")
struct RemoteControlMasterCleanupTests {
    private func configuration(
        destination: String = "cmux-macmini",
        port: Int? = 2222,
        identityFile: String? = "/Users/test/.ssh/id_ed25519",
        sshOptions: [String] = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/tmp/cmux-ssh-%C",
            "StrictHostKeyChecking=accept-new",
        ]
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: 64012,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
    }

    @Test("Cleanup argv is the frozen -O exit teardown with master/persist stripped")
    func cleanupArgumentsAreFrozen() {
        let cleanup = RemoteControlMasterCleanup()
        #expect(
            cleanup.cleanupArguments(configuration: configuration()) == [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @Test("Missing port and identity drop their flags but keep the teardown")
    func cleanupArgumentsWithoutPortOrIdentity() {
        let cleanup = RemoteControlMasterCleanup()
        let config = configuration(port: nil, identityFile: "   ", sshOptions: [])
        #expect(
            cleanup.cleanupArguments(configuration: config) == [
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-O", "exit",
                "cmux-macmini",
            ]
        )
    }

    @Test("Option-key parse is case-insensitive and splits on = or whitespace")
    func optionKeyParsing() {
        let cleanup = RemoteControlMasterCleanup()
        #expect(cleanup.optionKey("ControlMaster=auto") == "controlmaster")
        #expect(cleanup.optionKey("StrictHostKeyChecking accept-new") == "stricthostkeychecking")
        #expect(cleanup.optionKey("   ") == nil)
    }
}
