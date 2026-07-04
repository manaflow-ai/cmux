import Testing
import CmuxCore

@Suite("WorkspaceRemoteConfiguration SSH batch command composition")
struct WorkspaceRemoteConfigurationSSHBatchCommandsTests {
    private func configuration(
        sshOptions: [String] = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/tmp/cmux-ssh-%C",
            "StrictHostKeyChecking=accept-new",
        ],
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: sshOptions,
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

    /// Shared batch argv for `configuration()` (StrictHostKeyChecking already
    /// configured, so no `accept-new` injection; ControlMaster/ControlPersist
    /// dropped, ControlPath kept), derived from the legacy
    /// `WorkspaceRemoteSSHBatchCommandBuilder.batchArguments`.
    private let expectedBatchArguments: [String] = [
        "-o", "ConnectTimeout=6",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=2",
        "-o", "BatchMode=yes",
        "-o", "ControlMaster=no",
        "-p", "2222",
        "-i", "/Users/test/.ssh/id_ed25519",
        "-o", "ControlPath=/tmp/cmux-ssh-%C",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    @Test("daemonTransportArguments without a persistent slot")
    func daemonTransportArgumentsWithoutSlot() {
        let arguments = configuration().daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let expectedCommand = #"sh -c 'exec '"'"'/remote/cmuxd-remote'"'"' '"'"'serve'"'"' '"'"'--stdio'"'"''"#
        #expect(
            arguments == ["-T"]
                + expectedBatchArguments
                + ["-o", "RequestTTY=no", "cmux-macmini", expectedCommand]
        )
    }

    @Test("daemonTransportArguments with a persistent daemon slot")
    func daemonTransportArgumentsWithSlot() {
        let arguments = configuration(
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ws-1"
        ).daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let expectedCommand = #"sh -c 'exec '"'"'/remote/cmuxd-remote'"'"' '"'"'serve'"'"' '"'"'--stdio'"'"' '"'"'--persistent'"'"' '"'"'--slot'"'"' '"'"'ws-1'"'"''"#
        #expect(
            arguments == ["-T"]
                + expectedBatchArguments
                + ["-o", "RequestTTY=no", "cmux-macmini", expectedCommand]
        )
    }

    @Test("daemonTransportArguments injects accept-new and drops control master options")
    func daemonTransportArgumentsInjectsStrictHostKeyChecking() {
        let arguments = configuration(
            sshOptions: [
                "ControlMaster auto",
                "ControlPersist 600",
                "ControlPath /tmp/cmux-ssh-%C",
            ]
        ).daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let expectedCommand = #"sh -c 'exec '"'"'/remote/cmuxd-remote'"'"' '"'"'serve'"'"' '"'"'--stdio'"'"''"#
        #expect(
            arguments == [
                "-T",
                "-o", "ConnectTimeout=6",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=2",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath /tmp/cmux-ssh-%C",
                "-o", "RequestTTY=no",
                "cmux-macmini",
                expectedCommand,
            ]
        )
    }

    /// The stdio daemon transport appends its own positional remote command,
    /// which OpenSSH refuses while a host ssh_config `RemoteCommand` is in
    /// effect ("Cannot execute command-line and remote command.", issue
    /// #7246) — the argv must override it before the destination.
    @Test("daemonTransportArguments override a host-configured RemoteCommand")
    func daemonTransportArgumentsOverrideHostConfiguredRemoteCommand() {
        let arguments = configuration().daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let overrideIndex = arguments.indices.dropLast().first {
            arguments[$0] == "-o" && arguments[$0 + 1] == "RemoteCommand=none"
        }
        let destinationIndex = arguments.firstIndex(of: "cmux-macmini")
        #expect(overrideIndex != nil)
        #expect(destinationIndex != nil)
        if let overrideIndex, let destinationIndex {
            #expect(overrideIndex < destinationIndex)
        }
    }

    @Test("daemonSocketForwardArguments shape")
    func daemonSocketForwardArguments() {
        let arguments = configuration().daemonSocketForwardArguments(
            localPort: 64123,
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )
        #expect(
            arguments == ["-N", "-T", "-S", "none"]
                + expectedBatchArguments
                + [
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "RequestTTY=no",
                    "-L", "127.0.0.1:64123:/run/cmuxd-remote.sock",
                    "cmux-macmini",
                ]
        )
    }

    @Test("reverseRelayControlMasterArguments full argv with a configured ControlPath")
    func reverseRelayControlMasterArguments() throws {
        let arguments = try #require(
            configuration().reverseRelayControlMasterArguments(
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64007:127.0.0.1:54321"
            )
        )
        #expect(
            arguments == expectedBatchArguments
                + ["-O", "forward", "-R", "127.0.0.1:64007:127.0.0.1:54321", "cmux-macmini"]
        )
    }

    @Test("reverseRelayControlMasterCancelArguments full argv uses the remote listen port only")
    func reverseRelayControlMasterCancelArguments() throws {
        let arguments = try #require(
            configuration().reverseRelayControlMasterCancelArguments(relayPort: 64007)
        )
        #expect(
            arguments == expectedBatchArguments
                + ["-O", "cancel", "-R", "127.0.0.1:64007", "cmux-macmini"]
        )
    }

    @Test("reverse relay requires a usable ControlPath")
    func reverseRelayRequiresControlPath() {
        #expect(
            configuration(sshOptions: ["StrictHostKeyChecking=accept-new"])
                .reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: "127.0.0.1:64007:127.0.0.1:54321"
                ) == nil
        )
        #expect(
            configuration(sshOptions: ["ControlPath=None"])
                .reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: "127.0.0.1:64007:127.0.0.1:54321"
                ) == nil
        )
        #expect(configuration().reverseRelayControlMasterCancelArguments(relayPort: 0) == nil)
    }
}
