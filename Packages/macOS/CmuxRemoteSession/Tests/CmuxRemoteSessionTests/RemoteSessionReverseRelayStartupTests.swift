import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
import CmuxFoundation
@testable import CmuxRemoteSession
@testable import CmuxRemoteWorkspace

@Suite("Reverse relay startup lifecycle")
struct RemoteSessionReverseRelayStartupTests {
    @Test("Only the configured OpenSSH remote-bind error triggers migration recovery")
    func identifiesConfiguredPortBindingFailure() {
        #expect(RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "remote port forwarding failed for listen port 64044",
            relayPort: 64_044
        ))
        #expect(RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "Error: remote port forwarding failed for listen port 64044",
            relayPort: 64_044
        ))
        #expect(RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            """
            mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 64044
            muxclient: master forward request failed
            """,
            relayPort: 64_044
        ))
        #expect(!RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "remote port forwarding failed for listen port 64045",
            relayPort: 64_044
        ))
        #expect(!RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "Connection refused",
            relayPort: 64_044
        ))
    }

    @MainActor
    static func makeCoordinator(
        host: any RemoteSessionHosting = NoopRemoteSessionHost(),
        runner: any RemoteSessionProcessRunning,
        reverseRelayLauncher: any RemoteReverseRelayLaunching = RemoteReverseRelayLauncher(),
        relayPort: Int = 64_044,
        sshOptions: [String]? = nil,
        persistentDaemonSlot: String? = nil,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock(),
        providesResolvedControlPath: Bool = true,
        ownershipRegistry: any NativeSSHControlMasterOwnershipTracking =
            PermissiveNativeSSHControlMasterOwnershipRegistry()
    ) throws -> (coordinator: RemoteSessionCoordinator, scratchDirectory: URL) {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-reverse-relay-startup-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true
        )
        let rawConfiguration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: sshOptions ?? ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-startup-cancellation",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: scratchDirectory.appendingPathComponent("relay.sock").path,
            ownerWorkspaceID: UUID(),
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: persistentDaemonSlot != nil,
            persistentDaemonSlot: persistentDaemonSlot
        )
        let effectiveRunner: any RemoteSessionProcessRunning
        if providesResolvedControlPath {
            effectiveRunner = ResolvedControlPathProcessRunner(base: runner)
        } else {
            effectiveRunner = runner
        }
        let connectionBroker = NativeSSHConnectionBroker(
            sharingOptions: SSHConnectionSharingOptions(),
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            inheritedMasterReapRunner: effectiveRunner,
            controlMasterOwnershipRegistry: ownershipRegistry
        )
        let configuration = connectionBroker.retainWorkspace(rawConfiguration)
        let coordinator = RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
            connectionBroker: connectionBroker,
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: scratchDirectory
            ),
            processRunner: effectiveRunner,
            reverseRelayLauncher: reverseRelayLauncher,
            reachabilityProbe: SSHOverrideNoopReachabilityProbe(),
            relayCommandRewriter: SSHOverridePassthroughRelayCommandRewriter(),
            buildInfo: SSHOverrideStubBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@",
                reverseRelayUnavailableRetrying:
                    "test relay unavailable",
                reverseRelayPortUnavailableRetrying:
                    "test relay port unavailable",
                controlMasterOwnershipUnavailable:
                    "test control master unavailable"
            ),
            clock: clock
        )
        return (coordinator, scratchDirectory)
    }
}
