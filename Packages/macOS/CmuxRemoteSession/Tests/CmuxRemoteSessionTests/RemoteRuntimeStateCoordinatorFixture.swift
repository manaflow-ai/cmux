import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
@testable import CmuxRemoteSession

/// Owns one ready fake tunnel and coordinator for runtime-state tests.
final class RemoteRuntimeStateCoordinatorFixture {
    let provider = IntentionalCleanupTestTunnelProvider()
    let host: RuntimeStateRecordingHost
    let configuration: WorkspaceRemoteConfiguration
    let broker: RemoteProxyBroker
    let coordinator: RemoteSessionCoordinator
    let lease: RemoteProxyLease

    init(host: RuntimeStateRecordingHost = RuntimeStateRecordingHost()) {
        self.host = host
        configuration = WorkspaceRemoteConfiguration(
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
            persistentDaemonSlot: "runtime-test"
        )
        broker = RemoteProxyBroker(tunnelProvider: provider)
        coordinator = RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: broker,
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
        lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
    }

    func stop() {
        coordinator.stop()
        coordinator.queue.sync {}
        provider.tunnel.stop()
    }
}
