import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient required capabilities")
struct RemoteDaemonRPCClientCapabilityTests {
    private func configuration(
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        skipDaemonBootstrap: Bool = false
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
            persistentDaemonSlot: persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
    }

    @Test("the capability constants are the exact wire strings")
    func capabilityConstantsArePinned() {
        #expect(RemoteDaemonRPCClient.requiredProxyStreamCapability == "proxy.stream.push")
        #expect(RemoteDaemonRPCClient.requiredPTYSessionCapability == "pty.session")
        #expect(RemoteDaemonRPCClient.requiredPTYSessionTokenCapability == "pty.session.token")
        #expect(RemoteDaemonRPCClient.requiredPTYPersistentDaemonCapability == "pty.session.persistent_daemon")
        #expect(RemoteDaemonRPCClient.requiredPTYWriteNotificationCapability == "pty.write.notification")
        #expect(RemoteDaemonRPCClient.requiredPTYResizeNotificationCapability == "pty.resize.notification")
        #expect(RemoteDaemonRPCClient.optionalPTYInputSeqAckCapability == "pty.input.seq_ack")
        #expect(RemoteDaemonRPCClient.requiredFileReadCapability == "file.read")
        #expect(RemoteDaemonRPCClient.requiredFSStatCapability == "fs.stat")
        #expect(RemoteDaemonRPCClient.maximumRemoteFileReadBytes == 1_048_576)
        #expect(RemoteDaemonRPCClient.ptyInputSeqGapErrorCode == "pty_input_seq_gap")
    }

    @Test("a bootstrapped configuration requires proxy streaming and file access")
    func baseConfiguration() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(for: configuration())
                == ["proxy.stream.push", "file.read", "fs.stat"]
        )
    }

    @Test("preserveAfterTerminalExit adds the persistent-PTY capabilities in order")
    func preserveAfterTerminalExit() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(
                for: configuration(preserveAfterTerminalExit: true)
            ) == [
                "proxy.stream.push",
                "file.read",
                "fs.stat",
                "pty.session",
                "pty.session.token",
                "pty.write.notification",
                "pty.resize.notification",
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
                "file.read",
                "fs.stat",
                "pty.session",
                "pty.session.token",
                "pty.write.notification",
                "pty.resize.notification",
                "pty.session.persistent_daemon",
            ]
        )
    }

    @Test("a baked daemon remains compatible until its image carries file RPCs")
    func bakedDaemonDoesNotRequireFileAccess() {
        #expect(
            RemoteDaemonRPCClient.requiredCapabilities(
                for: configuration(skipDaemonBootstrap: true)
            ) == ["proxy.stream.push"]
        )
    }

    @Test("seq-ack is optional and never required for transport startup")
    func seqAckCapabilityIsOptional() {
        #expect(!RemoteDaemonRPCClient.requiredCapabilities(for: configuration()).contains("pty.input.seq_ack"))
        #expect(!RemoteDaemonRPCClient.requiredCapabilities(
            for: configuration(preserveAfterTerminalExit: true, persistentDaemonSlot: "slot")
        ).contains("pty.input.seq_ack"))
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
