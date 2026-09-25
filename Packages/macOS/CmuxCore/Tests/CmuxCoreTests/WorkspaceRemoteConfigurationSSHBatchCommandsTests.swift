import Testing
import CmuxCore
import CmuxFoundation
import Foundation

@Suite("WorkspaceRemoteConfiguration SSH batch command composition")
struct WorkspaceRemoteConfigurationSSHBatchCommandsTests {
    private func configuration(
        sshOptions: [String] = [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/tmp/cmux-ssh-%C",
            "StrictHostKeyChecking=accept-new",
        ],
        keepaliveSettings: SSHKeepaliveSettings? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        relayPort: Int? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: 2222,
            identityFile: "/Users/test/.ssh/id_ed25519",
            sshOptions: sshOptions,
            sshKeepaliveSettings: keepaliveSettings,
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

    @Test("Global keepalive defaults reach transports without becoming saved overrides")
    func configuredKeepalivesStayOutOfSnapshots() throws {
        let settings = try SSHKeepaliveSettings(sshServerAliveInterval: 60, sshServerAliveCountMax: 5)
        let original = configuration(sshOptions: ["ServerAliveCountMax=8"], keepaliveSettings: settings)
        let copies = [original, original.scopedToOwnerWorkspace(UUID()),
                      original.withSSHControlMasterLeaseGeneration(UUID()),
                      original.withDaemonWebSocketEndpoint(nil)]
        for copy in copies {
            let arguments = copy.daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
            #expect(arguments.contains(["-o", "ServerAliveInterval=60"]))
            #expect(arguments.contains(["-o", "ServerAliveCountMax=8"]))
            #expect(!arguments.contains(["-o", "ServerAliveCountMax=5"]))
            let snapshot = try #require(copy.sessionSnapshot())
            #expect(snapshot.sshOptions == ["ServerAliveCountMax=8"])
            let restored = configuration(sshOptions: snapshot.sshOptions,
                keepaliveSettings: try SSHKeepaliveSettings(sshServerAliveInterval: 90))
            #expect(restored.sshOptions == ["ServerAliveCountMax=8", "ServerAliveInterval=90"])
            let reset = configuration(sshOptions: snapshot.sshOptions)
            #expect(reset.daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
                .contains(["-o", "ServerAliveInterval=20"]))
        }
    }

    @Test("Global JSON settings validate values and preserve explicit option spellings")
    func keepaliveConfigurationDecoding() throws {
        let data = Data("""
        {
          "remote": { "sshServerAliveInterval": 60 }
        }
        """.utf8)
        let settings = try #require(try SSHKeepaliveSettings.decodeConfiguration(data))
        #expect(settings.sshServerAliveInterval == 60)
        #expect(settings.sshServerAliveCountMax == 2)
        #expect(settings.optionArguments(for: [" serveraliveinterval  90 ", "SERVERALIVECOUNTMAX=7"]).isEmpty)
        #expect(try SSHKeepaliveSettings.decodeConfiguration(Data("{}".utf8)) == nil)
        #expect(try SSHKeepaliveSettings.decodeConfiguration(Data(#"{"remote":{}}"#.utf8)) == .default)
        #expect(throws: (any Error).self) {
            try SSHKeepaliveSettings.decodeConfiguration(Data(#"{"remote":{"sshServerAliveInterval":0}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try SSHKeepaliveSettings.decodeConfiguration(Data(#"{"remote":{"sshServerAliveCountMax":101}}"#.utf8))
        }
    }

    @Test("daemonTransportArguments without a persistent slot")
    func daemonTransportArgumentsWithoutSlot() {
        let arguments = configuration().daemonTransportArguments(remotePath: "/remote/cmuxd-remote")
        let expectedCommand = #"sh -c 'exec '"'"'/remote/cmuxd-remote'"'"' '"'"'serve'"'"' '"'"'--stdio'"'"''"#
        #expect(
            arguments == ["-T", "-o", "RemoteCommand=none"]
                + expectedBatchArguments
                + ["-o", "RequestTTY=no", "cmux-macmini", expectedCommand]
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
                + ["-o", "RequestTTY=no", "cmux-macmini", expectedCommand]
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
                "cmux-macmini",
                expectedCommand,
            ]
        )
    }

    @Test("configured keepalives take precedence over batch defaults")
    func configuredKeepalivesTakePrecedence() {
        let arguments = configuration(
            sshOptions: [
                "ServerAliveInterval=60",
                "ServerAliveCountMax=5",
                "StrictHostKeyChecking=accept-new",
            ]
        ).daemonTransportArguments(remotePath: "/remote/cmuxd-remote")

        #expect(arguments.contains(["-o", "ServerAliveInterval=60"]))
        #expect(arguments.contains(["-o", "ServerAliveCountMax=5"]))
        #expect(!arguments.contains(["-o", "ServerAliveInterval=20"]))
        #expect(!arguments.contains(["-o", "ServerAliveCountMax=2"]))
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
                "-p", "2222",
                "-i", "/Users/test/.ssh/id_ed25519",
                "-o", "ControlPath=/tmp/cmux-ssh-resolved",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "RequestTTY=no",
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
}
