import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote PTY intentional cleanup")
struct RemotePTYIntentionalCleanupTests {
    @Test("a second coordinator observes and acknowledges the shared tunnel generation")
    func lifecycleIsSharedAcrossCoordinators() throws {
        let provider = IntentionalCleanupTestTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider)
        let configuration = Self.configuration()
        let first = Self.coordinator(configuration: configuration, broker: broker)
        let second = Self.coordinator(configuration: configuration, broker: broker)
        let firstLease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        let secondLease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        let sessionID = "ssh-workspace-surface"
        let lifecycleID = "logical-surface-generation"

        Self.markReady(first, lease: firstLease)
        Self.markReady(second, lease: secondLease)
        defer {
            first.stop()
            second.stop()
            provider.tunnel.stop()
        }

        _ = try first.startPTYBridge(
            sessionID: sessionID,
            lifecycleID: lifecycleID,
            attachmentID: "surface",
            command: nil,
            requireExisting: false
        )
        try first.closePTYSession(sessionID: sessionID)

        #expect(try second.ptySessionLifecycle(
            sessionID: sessionID,
            lifecycleID: lifecycleID
        ) == .intentionallyClosed)
        try second.acknowledgePTYLifecycle(sessionID: sessionID, lifecycleID: lifecycleID)
        for requireExisting in [true, false] {
            #expect(throws: RemotePTYLifecycleError.self) {
                try second.startPTYBridge(
                    sessionID: sessionID,
                    lifecycleID: lifecycleID,
                    attachmentID: "surface",
                    command: nil,
                    requireExisting: requireExisting
                )
            }
        }
        #expect(provider.makeCount == 1)
    }

    @Test("terminal wrapper end retires its shared generation after coordinator shutdown")
    func wrapperEndRetiresGenerationAfterCoordinatorShutdown() throws {
        let provider = IntentionalCleanupTestTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider)
        let configuration = Self.configuration()
        let coordinator = Self.coordinator(configuration: configuration, broker: broker)
        let lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        let survivorLease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        Self.markReady(coordinator, lease: lease)
        defer { survivorLease.release(); provider.tunnel.stop() }

        _ = try coordinator.startPTYBridge(
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "wrapper-generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: false
        )
        coordinator.stop()
        coordinator.queue.sync {}
        coordinator.acknowledgePTYLifecycleAfterWrapperEnd(
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "wrapper-generation"
        )

        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "UPPERCASE-SESSION",
            lifecycleID: "wrapper-generation"
        ) == .intentionallyClosed)
    }

    private static func markReady(_ coordinator: RemoteSessionCoordinator, lease: RemoteProxyLease) {
        coordinator.queue.sync {
            coordinator.proxyLease = lease
            coordinator.proxyEndpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 42_424)
            coordinator.daemonReady = true
        }
    }

    private static func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: nil
        )
    }

    private static func coordinator(
        configuration: WorkspaceRemoteConfiguration,
        broker: RemoteProxyBroker
    ) -> RemoteSessionCoordinator {
        RemoteSessionCoordinator(
            host: IntentionalCleanupTestHost(),
            configuration: configuration,
            proxyBroker: broker,
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: IntentionalCleanupUnusedProcessRunner(),
            reachabilityProbe: IntentionalCleanupNoopReachabilityProbe(),
            relayCommandRewriter: IntentionalCleanupRelayCommandRewriter(),
            buildInfo: IntentionalCleanupBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            )
        )
    }
}
