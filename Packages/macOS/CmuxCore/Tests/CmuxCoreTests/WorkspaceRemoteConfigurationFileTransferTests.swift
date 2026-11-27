import Foundation
import Testing
import CmuxCore
import CmuxFoundation

// A workspace opened by `cmux ssh` can be handed `__cmux_route_sensitive=<digest>`
// in its options. It is cmux's own note about which shared connection the
// route may use, not an OpenSSH option, and `scp` rejects it: dropping a file
// into such a workspace failed with "Bad configuration option:
// __cmux_route_sensitive" (https://github.com/manaflow-ai/cmux/issues/20220).
// The remote file explorer, file preview, reachability probe and legacy
// uploads write the same options out, so the marker must never be in them.
@Suite("WorkspaceRemoteConfiguration keeps the route marker out of its OpenSSH options")
struct WorkspaceRemoteConfigurationFileTransferTests {
    private let digest = String(repeating: "a1", count: 32)
    private var routeMarker: String { "__cmux_route_sensitive=" + digest }
    private let sharing = SSHConnectionSharingOptions(
        userID: 501,
        controlSocketDirectoryPath: "/tmp/cmux-route-marker-tests"
    )

    private func configuration(
        sshOptions: [String],
        identityFile: String? = nil,
        agentSocketPath: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "dev@my-host",
            port: nil,
            identityFile: identityFile,
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

    @Test("a handed-off marker becomes the route identifier, not an option")
    func markerMovesOutOfOptions() {
        let configuration = configuration(
            sshOptions: ["ControlMaster=auto", routeMarker, "ControlPersist=600"]
        )

        #expect(configuration.sshOptions == ["ControlMaster=auto", "ControlPersist=600"])
        #expect(configuration.routeSensitiveIdentifier == digest)
        #expect(configuration.routeSensitivity == .identified(digest))
    }

    @Test("scp, ssh and sftp never see the marker", arguments: [
        "__cmux_route_sensitive=" + String(repeating: "a1", count: 32),
        "__cmux_route_sensitive=true",
        "__CMUX_ROUTE_SENSITIVE=true",
        "  __cmux_route_sensitive=true  ",
        "__cmux_route_sensitive true",
        "__cmux_route_sensitive",
    ])
    func markerNeverReachesOpenSSH(marker: String) {
        let configuration = configuration(
            sshOptions: ["ProxyJump=bastion", marker, "UserKnownHostsFile=/dev/null"],
            agentSocketPath: "/tmp/agent.sock"
        )

        #expect(configuration.sshOptions == ["ProxyJump=bastion", "UserKnownHostsFile=/dev/null"])
        for options in [
            configuration.sshOptions,
            configuration.mergingConnectionSharingDefaults(sharing),
        ] {
            #expect(!options.contains { $0.lowercased().contains("__cmux_route_sensitive") })
        }
    }

    @Test("options that only mention the marker are kept, in order")
    func otherOptionsAreKept() {
        let sshOptions = [
            "IgnoreUnknown=__cmux_*",
            "ProxyCommand=/bin/sh -c 'echo __cmux_route_sensitive=1'",
            "SetEnv=NOTE=__cmux_route_sensitive",
            "StrictHostKeyChecking=accept-new",
        ]

        #expect(configuration(sshOptions: sshOptions).sshOptions == sshOptions)
        #expect(configuration(sshOptions: sshOptions + [routeMarker]).sshOptions == sshOptions)
    }

    @Test("the connection-sharing merge still picks the route's private master")
    func connectionSharingMatchesTheMarkerInOptions() {
        for identityFile in [nil, "~/.ssh/id_work"] as [String?] {
            let routeSensitiveOptions = identityFile.map { ["IdentityFile=\($0)"] } ?? []
            let configuration = configuration(
                sshOptions: ["ProxyJump=bastion", routeMarker],
                identityFile: identityFile
            )
            // The merge before this change, with the marker inside the options.
            let previous = sharing.mergingDefaults(
                into: ["ProxyJump=bastion", routeMarker],
                routeSensitiveOptions: routeSensitiveOptions
            )

            let merged = configuration.mergingConnectionSharingDefaults(
                sharing,
                routeSensitiveOptions: routeSensitiveOptions
            )
            #expect(merged == previous)
            let controlPath = merged.first { $0.hasPrefix("ControlPath=") }
            #expect(controlPath?.hasPrefix("ControlPath=/tmp/cmux-route-marker-tests/") == true)
            #expect(controlPath?.hasSuffix("/%C") == false)
        }
        // Without a marker the route keeps the shared `%C` master.
        #expect(configuration(sshOptions: []).mergingConnectionSharingDefaults(sharing)
            == sharing.mergingDefaults(into: []))
    }

    @Test("a sensitive route without a digest never shares a master", arguments: [
        "__cmux_route_sensitive=true",
        "__CMUX_ROUTE_SENSITIVE=true",
        "__cmux_route_sensitive true",
    ])
    func unidentifiedSensitiveRouteStaysUnshared(marker: String) throws {
        let configuration = configuration(sshOptions: ["ProxyJump=bastion", marker])

        #expect(configuration.routeSensitivity == .unidentified)
        #expect(configuration.routeSensitiveIdentifier == nil)
        #expect(configuration.sshOptions == ["ProxyJump=bastion"])
        let merged = configuration.mergingConnectionSharingDefaults(sharing)
        #expect(merged == sharing.mergingDefaults(into: ["ProxyJump=bastion", marker]))
        #expect(merged.contains("ControlPath=none"))
        #expect(!merged.contains { $0.hasSuffix("/%C") })

        // Saving and restoring keeps the route unshared.
        let snapshot = try #require(configuration.sessionSnapshot())
        #expect(self.configuration(sshOptions: snapshot.sshOptions).routeSensitivity == .unidentified)
        #expect(configuration != self.configuration(sshOptions: ["ProxyJump=bastion"]))
    }

    @Test("a saved workspace keeps its route across save and restore")
    func snapshotRoundTripKeepsTheRoute() throws {
        let configuration = configuration(sshOptions: ["ProxyJump=bastion", routeMarker])

        let snapshot = try #require(configuration.sessionSnapshot())
        // The saved format is unchanged, so older and newer cmux read it alike.
        #expect(snapshot.sshOptions.contains(routeMarker))

        let restored = self.configuration(sshOptions: snapshot.sshOptions)
        #expect(restored.routeSensitiveIdentifier == digest)
        #expect(!restored.sshOptions.contains(routeMarker))
        #expect(restored.proxyBrokerTransportKey == configuration.proxyBrokerTransportKey)
    }

    @Test("copies keep the route identifier")
    func copiesKeepTheRoute() {
        let configuration = configuration(sshOptions: [routeMarker])

        for copy in [
            configuration.scopedToOwnerWorkspace(UUID()),
            configuration.withDaemonWebSocketEndpoint(nil),
            configuration.withSSHControlMasterLeaseGeneration(UUID()),
            configuration.withResolvedSSHControlPath("/tmp/cmux-route-marker-tests/abc"),
        ] {
            #expect(copy.routeSensitivity == .identified(digest))
        }
    }

    @Test("routes that differ only by marker stay distinct")
    func routesThatDifferOnlyByMarkerStayDistinct() {
        let plain = configuration(sshOptions: ["ProxyJump=bastion"])
        let routed = configuration(sshOptions: ["ProxyJump=bastion", routeMarker])

        #expect(plain != routed)
        #expect(plain.proxyBrokerTransportKey != routed.proxyBrokerTransportKey)
    }
}
