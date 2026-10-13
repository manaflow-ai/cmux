import Testing
import CmuxCore

// A workspace opened by `cmux ssh` can carry `__cmux_route_sensitive=<digest>`
// in its options. It is cmux's own note about which shared connection the
// route may use, not an OpenSSH option, and `scp` rejects it: dropping a file
// into such a workspace failed with "Bad configuration option:
// __cmux_route_sensitive" (https://github.com/manaflow-ai/cmux/issues/20220).
// The remote file explorer and file preview write the same options out.
@Suite("WorkspaceRemoteConfiguration options handed to OpenSSH")
struct WorkspaceRemoteConfigurationFileTransferTests {
    private let routeMarker = "__cmux_route_sensitive=" + String(repeating: "a1", count: 32)

    private func configuration(
        sshOptions: [String],
        agentSocketPath: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "dev@my-host",
            port: nil,
            identityFile: nil,
            sshOptions: sshOptions,
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            agentSocketPath: agentSocketPath
        )
    }

    @Test("the private route marker is not handed to scp")
    func routeMarkerIsNotAFileTransferOption() {
        let options = configuration(
            sshOptions: ["ControlMaster=auto", "ControlPersist=600", routeMarker]
        ).fileTransferSSHOptions

        #expect(options == ["ControlMaster=auto", "ControlPersist=600"])
    }

    @Test("the private route marker is not handed to ssh or sftp")
    func routeMarkerIsNotAnOpenSSHOption() {
        let configuration = configuration(
            sshOptions: ["ControlMaster=auto", routeMarker, "ControlPersist=600"],
            agentSocketPath: "/tmp/agent.sock"
        )

        #expect(configuration.openSSHOptions == ["ControlMaster=auto", "ControlPersist=600"])
        // The stored options are untouched: the connection code still reads the marker.
        #expect(configuration.sshOptions.contains(routeMarker))
    }

    @Test("the marker is dropped however it is written", arguments: [
        "__cmux_route_sensitive=true",
        "__CMUX_ROUTE_SENSITIVE=true",
        "  __cmux_route_sensitive=true  ",
        "__cmux_route_sensitive true",
        "__cmux_route_sensitive",
    ])
    func routeMarkerIsDroppedInAnySpelling(marker: String) {
        let options = configuration(
            sshOptions: ["ProxyJump=bastion", marker, "UserKnownHostsFile=/dev/null"]
        )

        #expect(options.openSSHOptions == ["ProxyJump=bastion", "UserKnownHostsFile=/dev/null"])
        #expect(options.fileTransferSSHOptions == ["ProxyJump=bastion", "UserKnownHostsFile=/dev/null"])
    }

    @Test("every other option is kept, in order, with the agent socket first")
    func otherOptionsAreKept() {
        let sshOptions = [
            "IgnoreUnknown=__cmux_*",
            "ProxyCommand=/bin/sh -c 'echo __cmux_route_sensitive=1'",
            "SetEnv=NOTE=__cmux_route_sensitive",
            "StrictHostKeyChecking=accept-new",
        ]

        #expect(configuration(sshOptions: sshOptions).fileTransferSSHOptions == sshOptions)
        #expect(configuration(sshOptions: sshOptions).openSSHOptions == sshOptions)
        #expect(
            configuration(sshOptions: sshOptions + [routeMarker], agentSocketPath: "/tmp/agent.sock")
                .fileTransferSSHOptions == ["IdentityAgent=/tmp/agent.sock"] + sshOptions
        )
        #expect(configuration(sshOptions: [routeMarker]).fileTransferSSHOptions.isEmpty)
    }
}
