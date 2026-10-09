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

    @Test("Only canonical OpenSSH authentication markers are classified")
    func identifiesSSHAuthenticationFailure() {
        #expect(
            RemoteRelayAuthenticationFailure.detect(
                in: "user@example.test: Permission denied (publickey,password)."
            ) == .permissionDenied(methods: "publickey, password")
        )
        #expect(
            RemoteRelayAuthenticationFailure.detect(
                in: "Received disconnect from 192.0.2.1 port 22:2: Too many authentication failures"
            ) == .tooManyAuthenticationFailures
        )
        #expect(
            RemoteRelayAuthenticationFailure.detect(
                in: "Permission denied: caller-controlled diagnostic"
            ) == nil
        )
        for diagnostic in [
            "debug1: ProxyCommand echo Permission denied (publickey).",
            "debug1: echo Too many authentication failures",
            "Permission denied (secret-canary).",
            "user@example.test: Permission denied (publickey). secret-canary",
            "Permission denied (publickey).\nError: remote port forwarding failed for listen port 64044",
            "Load key /tmp/key: Permission denied",
            "Error: remote port forwarding failed for listen port 64044",
            "ssh: connect to host example.test port 22: Connection refused",
        ] {
            let classified = RemoteRelayAuthenticationFailure.detect(in: diagnostic) != nil
            #expect(!classified)
        }
    }

    @MainActor
    static func makeCoordinator(
        host: any RemoteSessionHosting = NoopRemoteSessionHost(),
        runner: any RemoteSessionProcessRunning,
        reverseRelayLauncher: any RemoteReverseRelayLaunching = RemoteReverseRelayLauncher(),
        relayPort: Int? = nil,
        sshOptions: [String]? = nil,
        persistentDaemonSlot: String? = nil,
        agentSocketPath: String? = nil,
        identity: ResolvedControlPathFixture.Identity? = nil,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock(),
        providesResolvedControlPath: Bool = true,
        ownershipRegistry: any NativeSSHControlMasterOwnershipTracking =
            PermissiveNativeSSHControlMasterOwnershipRegistry()
    ) throws -> (
        coordinator: RemoteSessionCoordinator,
        scratchDirectory: URL,
        identity: ResolvedControlPathFixture.Identity
    ) {
        let identity = identity ?? ResolvedControlPathFixture.uniqueIdentity()
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
            // Keep the shared-master fixture on cmux's default ControlMaster
            // path. Route-sensitive options such as StrictHostKeyChecking
            // intentionally disable sharing and belong only in tests that
            // exercise that behavior explicitly.
            sshOptions: sshOptions ?? [],
            localProxyPort: nil,
            relayPort: relayPort ?? identity.relayPort,
            relayID: identity.relayID,
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: scratchDirectory.appendingPathComponent("relay.sock").path,
            ownerWorkspaceID: UUID(),
            terminalStartupCommand: nil,
            agentSocketPath: agentSocketPath,
            preserveAfterTerminalExit: persistentDaemonSlot != nil,
            persistentDaemonSlot: persistentDaemonSlot
        )
        let effectiveRunner: any RemoteSessionProcessRunning
        if providesResolvedControlPath {
            effectiveRunner = ResolvedControlPathProcessRunner(
                base: runner,
                controlPath: identity.controlPath
            )
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
                missingRequiredFunctionality: "",
                cloudNotificationClearWorkspaceInvalid: "",
                cloudNotificationClearWorkspaceDenied: "",
                cloudNotificationClearSurfaceInvalid: ""
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
        return (coordinator, scratchDirectory, identity)
    }
}
