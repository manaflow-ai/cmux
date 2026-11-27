import CmuxCore
import CmuxFoundation
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

// Fixtures for ``RemoteSessionReadinessParkingTests``, split out to keep both
// files well inside the Swift file-length budget.
extension RemoteSessionReadinessParkingTests {
    static let requiredCapabilities = [
        RemoteDaemonRPCClient.requiredProxyStreamCapability,
    ]

    /// Awaits `operation`, giving up after `limit`.
    ///
    /// The fake clock hands out sleep requests through a continuation that
    /// cancellation cannot interrupt, so a request that never comes (the bug
    /// these tests pin) would hang the run past any time limit. Racing two
    /// unstructured tasks keeps that failure a prompt, ordinary expectation
    /// failure; the first writer wins the slot and resumes the caller once.
    static func value<Value: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let slot = LockedResult<Value?>()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await operation()
                if slot.setIfEmpty(.success(value)) { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if slot.setIfEmpty(.success(nil)) { continuation.resume(returning: nil) }
            }
        }
    }

    static func failureDescription<Success>(
        of result: Result<Success, any Error>
    ) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.localizedDescription
    }

    @MainActor
    static func makeCoordinator(
        host: any RemoteSessionHosting,
        runner: any RemoteSessionProcessRunning,
        proxyBroker: any RemoteProxyBrokering = SSHOverrideUnusedRemoteProxyBroker(),
        reverseRelayLauncher: any RemoteReverseRelayLaunching = RecordingReverseRelayLauncher(),
        relayPort: Int? = 64_044,
        skipDaemonBootstrap: Bool = false,
        clock: any RemoteProxyRetryClock
    ) throws -> ReadinessCoordinatorFixture {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true
        )
        let effectiveRunner = ResolvedControlPathProcessRunner(base: runner)
        let connectionBroker = NativeSSHConnectionBroker(
            sharingOptions: SSHConnectionSharingOptions(),
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            inheritedMasterReapRunner: effectiveRunner,
            controlMasterOwnershipRegistry: PermissiveNativeSSHControlMasterOwnershipRegistry()
        )
        let configuration = connectionBroker.retainWorkspace(
            WorkspaceRemoteConfiguration(
                destination: "user@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: ["StrictHostKeyChecking=accept-new"],
                localProxyPort: nil,
                relayPort: relayPort,
                relayID: relayPort == nil ? nil : "relay-readiness",
                relayToken: relayPort == nil ? nil : String(repeating: "a", count: 64),
                localSocketPath: relayPort == nil
                    ? nil
                    : scratchDirectory.appendingPathComponent("relay.sock").path,
                ownerWorkspaceID: UUID(),
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: false,
                persistentDaemonSlot: nil,
                skipDaemonBootstrap: skipDaemonBootstrap
            )
        )
        let coordinator = RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: proxyBroker,
            connectionBroker: connectionBroker,
            manifestRepository: RemoteDaemonManifestRepository(homeDirectory: scratchDirectory),
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
                reverseRelayUnavailableRetrying: "test relay unavailable",
                reverseRelayPortUnavailableRetrying: "test relay port unavailable",
                controlMasterOwnershipUnavailable: "test control master unavailable"
            ),
            clock: clock
        )
        // Port discovery is off (the sidebar-ports-hidden configuration), so the
        // bootstrap-TTY retry never requests sleeps on the clock under test.
        coordinator.queue.sync { coordinator.remotePortScanningEnabled = false }
        return ReadinessCoordinatorFixture(
            coordinator: coordinator,
            scratchDirectory: scratchDirectory
        )
    }
}
