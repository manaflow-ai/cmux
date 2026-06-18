import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient required capabilities")
struct RemoteDaemonRPCClientCapabilityTests {
    private func configuration(
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "user@example-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot
        )
    }

    @Test("the capability constants are the exact wire strings")
    func capabilityConstantsArePinned() {
        #expect(RemoteDaemonRPCClient.requiredProxyStreamCapability == "proxy.stream.push")
        #expect(RemoteDaemonRPCClient.requiredPTYSessionCapability == "pty.session")
        #expect(RemoteDaemonRPCClient.requiredPTYSessionTokenCapability == "pty.session.token")
        #expect(RemoteDaemonRPCClient.requiredPTYPersistentDaemonCapability == "pty.session.persistent_daemon")
        #expect(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability == "pty.write.notification")
    }

    @Test("a base configuration only requires proxy streaming")
    func baseConfiguration() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(for: configuration())
                == ["proxy.stream.push"]
        )
    }

    @Test("preserveAfterTerminalExit adds the persistent-PTY capabilities in order")
    func preserveAfterTerminalExit() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(
                for: configuration(preserveAfterTerminalExit: true)
            ) == [
                "proxy.stream.push",
                "pty.session",
                "pty.session.token",
                "pty.write.notification",
            ]
        )
    }

    @Test("a persistent daemon slot additionally requires the persistent-daemon capability")
    func persistentDaemonSlot() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(
                for: configuration(
                    preserveAfterTerminalExit: true,
                    persistentDaemonSlot: "workspace-1"
                )
            ) == [
                "proxy.stream.push",
                "pty.session",
                "pty.session.token",
                "pty.write.notification",
                "pty.session.persistent_daemon",
            ]
        )
    }

    @Test("missingRequiredCapabilities filters advertised capabilities preserving order")
    func missingRequiredCapabilities() {
        #expect(
            RemoteDaemonRPCClient.missingRequiredCapabilities(
                ["proxy.stream.push", "pty.session", "pty.session.token"],
                in: ["pty.session"]
            ) == ["proxy.stream.push", "pty.session.token"]
        )
        #expect(
            RemoteDaemonRPCClient.missingRequiredCapabilities(
                ["proxy.stream.push"],
                in: ["proxy.stream.push", "pty.session"]
            ).isEmpty
        )
        #expect(
            RemoteDaemonRPCClient.missingRequiredCapabilities([], in: []).isEmpty
        )
    }
}
