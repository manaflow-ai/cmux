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
        persistentDaemonSlot: String? = nil,
        relayPort: Int? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: relayPort,
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
            arguments == ["-T", "-o", "RemoteCommand=none"]
                + expectedBatchArguments
                + ["-o", "RequestTTY=no", "--", "cmux-macmini", expectedCommand]
        )
    }

    @Test("daemonTransportArguments with a persistent daemon slot")
    func daemonTransportArgumentsWithSlot() {
        let arguments = configuration(
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ws-1",
            relayPort: 64_007
        ).daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let expectedCommand = #"sh -c 'exec '"'"'/remote/cmuxd-remote'"'"' '"'"'serve'"'"' '"'"'--stdio'"'"' '"'"'--persistent'"'"' '"'"'--slot'"'"' '"'"'ws-1'"'"' '"'"'--persistent-lease-port'"'"' '"'"'64007'"'"''"#
        #expect(
            arguments == ["-T", "-o", "RemoteCommand=none"]
                + expectedBatchArguments
                + ["-o", "RequestTTY=no", "--", "cmux-macmini", expectedCommand]
        )
    }

    @Test("daemonTransportArguments keeps persistent transport compatible without a relay lease")
    func daemonTransportArgumentsWithoutPersistentLeasePort() {
        let arguments = configuration(
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ws-1"
        ).daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        #expect(arguments.last?.contains("--persistent-lease-port") == false)
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
                "-o", "RemoteCommand=none",
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
                "--",
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
            localSocketPath: "/private/tmp/cmuxd.AbC123/d.sock",
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )
        #expect(
            arguments == [
                "-N", "-T", "-S", "none",
                "-o", "StreamLocalBindMask=0177",
                "-o", "StreamLocalBindUnlink=yes",
                "-o", "ConnectTimeout=6",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=2",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-%C",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "/private/tmp/cmuxd.AbC123/d.sock:/run/cmuxd-remote.sock",
                "--",
                "cmux-macmini",
            ]
        )
    }

    /// OpenSSH keeps the first value of an option, so a configured
    /// `StreamLocalBindMask` must not be able to widen the socket's mode.
    @Test("daemonSocketForwardArguments bind options precede configured options")
    func daemonSocketForwardBindOptionsLead() {
        let arguments = configuration(sshOptions: [
            "StreamLocalBindMask=0000",
            "StreamLocalBindUnlink=no",
            "StrictHostKeyChecking=accept-new",
        ]).daemonSocketForwardArguments(
            localSocketPath: "/private/tmp/cmuxd.AbC123/d.sock",
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )
        let optionValues = arguments.indices.dropLast()
            .filter { arguments[$0] == "-o" }
            .map { arguments[$0 + 1].lowercased() }
        #expect(optionValues.first { $0.hasPrefix("streamlocalbindmask") } == "streamlocalbindmask=0177")
        #expect(optionValues.first { $0.hasPrefix("streamlocalbindunlink") } == "streamlocalbindunlink=yes")
    }

    @Test("reverseRelayControlMasterArguments uses the configured ControlPath")
    func reverseRelayControlMasterArguments() throws {
        let configuration = configuration()
        let arguments = try #require(
            configuration.reverseRelayControlMasterArguments(
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64007:127.0.0.1:54321",
                effectiveSSHOptions: configuration.sshOptions
            )
        )
        #expect(
            arguments == expectedBatchArguments
                + [
                    "-O", "forward",
                    "-R", "127.0.0.1:64007:127.0.0.1:54321",
                    "--",
                    "cmux-macmini",
                ]
        )
    }

    @Test("batch command reuses the supplied authenticated ControlPath")
    func batchCommandUsesEffectiveControlPath() {
        let effectiveOptions = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/tmp/cmux-ssh-resolved",
            "StrictHostKeyChecking=accept-new",
        ]

        #expect(
            configuration().batchSSHCommandArguments(
                command: "printf relay-metadata",
                effectiveSSHOptions: effectiveOptions
            ) == [
                "-T",
                "-o", "RemoteCommand=none",
                "-o", "ConnectTimeout=6",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=2",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=no",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "ClearAllForwardings=yes",
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-resolved",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "RequestTTY=no",
                "--",
                "cmux-macmini",
                "printf relay-metadata",
            ]
        )
    }

    @Test("resolved ControlPath replaces every unresolved option")
    func resolvedControlPathReplacesTemplates() {
        let resolved = configuration(
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlPath=/tmp/cmux-ssh-%C",
                "ControlPath=~/.ssh/ignored-%C",
            ]
        ).withResolvedSSHControlPath("/tmp/cmux-ssh-resolved")

        #expect(resolved.sshOptions == [
            "ControlPath=/tmp/cmux-ssh-resolved",
            "StrictHostKeyChecking=accept-new",
        ])
    }

    @Test("reverse relay ControlMaster commands require a usable ControlPath")
    func reverseRelayRequiresControlPath() {
        #expect(
            configuration(sshOptions: ["StrictHostKeyChecking=accept-new"])
                .reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: "127.0.0.1:64007:127.0.0.1:54321",
                    effectiveSSHOptions: ["StrictHostKeyChecking=accept-new"]
                ) == nil
        )
        #expect(
            configuration(sshOptions: ["ControlPath=None"])
                .reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: "127.0.0.1:64007:127.0.0.1:54321",
                    effectiveSSHOptions: ["ControlPath=None"]
                ) == nil
        )
        #expect(
            configuration(sshOptions: [
                "ControlMaster=no",
                "ControlPath=~/.ssh/custom-%C",
            ])
                .reverseRelayControlMasterArguments(
                    controlCommand: "forward",
                    forwardSpec: "127.0.0.1:64007:127.0.0.1:54321",
                    effectiveSSHOptions: [
                        "ControlMaster=no",
                        "ControlPath=~/.ssh/custom-%C",
                    ]
                ) == nil
        )
    }

    @Test("Every batch builder ends option parsing before the destination")
    func batchBuildersEndOptionParsingBeforeTheDestination() throws {
        let configuration = configuration()
        let builders: [[String]] = [
            configuration.daemonTransportArguments(remotePath: "/remote/cmuxd-remote"),
            configuration.daemonSocketForwardArguments(
                localSocketPath: "/tmp/cmux-test-daemon.sock",
                remoteSocketPath: "/run/cmuxd-remote.sock"
            ),
            try #require(configuration.reverseRelayControlMasterArguments(
                controlCommand: "forward",
                forwardSpec: "127.0.0.1:64007:127.0.0.1:54321",
                effectiveSSHOptions: configuration.sshOptions
            )),
            configuration.batchSSHCommandArguments(
                command: "printf relay-metadata",
                effectiveSSHOptions: configuration.sshOptions
            ),
        ]
        for arguments in builders {
            let destinationIndex = try #require(arguments.lastIndex(of: "cmux-macmini"))
            #expect(destinationIndex > 0 && arguments[destinationIndex - 1] == "--")
        }
    }

    /// A batch command never needs the user's agent, X11 display or port
    /// forwards. Each override precedes the configured options because
    /// OpenSSH keeps the first value it obtains.
    @Test("batch command turns off forwarding ahead of configured options")
    func batchCommandTurnsOffForwarding() throws {
        let configured = ["ForwardAgent=yes", "ForwardX11=yes", "ClearAllForwardings=no"]
        let arguments = configuration(sshOptions: configured).batchSSHCommandArguments(
            command: "printf relay-metadata",
            effectiveSSHOptions: configured
        )
        for (override, option) in zip(
            ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes"],
            configured
        ) {
            let overrideIndex = try #require(pairIndex(arguments, "-o", override))
            let configuredIndex = try #require(pairIndex(arguments, "-o", option))
            #expect(overrideIndex < configuredIndex)
        }
    }

    /// The socket forward needs its own `-L`, so it cannot clear forwardings,
    /// but it never needs the user's agent or X11 display.
    @Test("socket forward turns off agent and X11 forwarding but keeps its -L")
    func socketForwardTurnsOffAgentAndX11Forwarding() throws {
        let configured = ["ForwardAgent=yes", "ForwardX11=yes"]
        let arguments = configuration(sshOptions: configured).daemonSocketForwardArguments(
            localSocketPath: "/tmp/cmux-test-daemon.sock",
            remoteSocketPath: "/run/cmuxd-remote.sock"
        )
        for (override, option) in zip(["ForwardAgent=no", "ForwardX11=no"], configured) {
            let overrideIndex = try #require(pairIndex(arguments, "-o", override))
            let configuredIndex = try #require(pairIndex(arguments, "-o", option))
            #expect(overrideIndex < configuredIndex)
        }
        #expect(pairIndex(arguments, "-o", "ClearAllForwardings=yes") == nil)
        #expect(pairIndex(arguments, "-L", "/tmp/cmux-test-daemon.sock:/run/cmuxd-remote.sock") != nil)
    }

    private func pairIndex(_ arguments: [String], _ first: String, _ second: String) -> Int? {
        arguments.indices.dropLast().first { arguments[$0] == first && arguments[$0 + 1] == second }
    }
}
