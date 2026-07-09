import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote PTY intentional cleanup")
struct RemotePTYIntentionalCleanupTests {
    @Test("cleanup of an attached PTY prevents the require-existing reconnect loop")
    func attachedCleanupStopsReconnect() throws {
        let provider = IntentionalCleanupTestTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider)
        let configuration = Self.configuration()
        let coordinator = Self.coordinator(configuration: configuration, broker: broker)
        let lease = broker.acquire(configuration: configuration, remotePath: "/remote/cmuxd") { _ in }
        let sessionID = "ssh-workspace-surface"

        coordinator.queue.sync {
            coordinator.proxyLease = lease
            coordinator.proxyEndpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 42_424)
            coordinator.daemonReady = true
        }
        defer {
            coordinator.stop()
            provider.tunnel.stop()
        }

        _ = try coordinator.startPTYBridge(
            sessionID: sessionID,
            attachmentID: "surface",
            command: nil,
            requireExisting: false
        )
        try coordinator.closePTYSession(sessionID: sessionID)

        #expect(throws: (any Error).self) {
            try coordinator.startPTYBridge(
                sessionID: sessionID,
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
        }
        #expect(provider.tunnel.calls == [
            .init(name: "bridge", sessionID: sessionID),
            .init(name: "close", sessionID: sessionID),
        ])
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

private struct IntentionalCleanupTestHost: RemoteSessionHosting {
    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {}
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}

private struct IntentionalCleanupUnusedProcessRunner: RemoteSessionProcessRunning {
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        fatalError("Intentional cleanup tests do not spawn processes")
    }
}

private struct IntentionalCleanupNoopReachabilityProbe: RemoteHostReachabilityProbing {
    func probe(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        completion: @escaping @Sendable (RemoteHostProbeOutcome) -> Void
    ) {}
}

private struct IntentionalCleanupRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        commandLine
    }
}

private struct IntentionalCleanupBuildInfo: RemoteSessionBuildInfoProviding {
    func appVersion() -> String? { nil }
    func embeddedDaemonManifest() -> WorkspaceRemoteDaemonManifest? { nil }
    func executableDirectoryURL() -> URL? { nil }
}
