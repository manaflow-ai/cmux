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
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
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

struct RecordedReverseRelayLaunch: Sendable {
    let arguments: [String]
    let localRelayPort: Int
    let startupMarker: String
}

/// Synchronous launcher callbacks cannot await; the lock protects only callback snapshots and a counter.
final class RecordingReverseRelayLauncher:
    RemoteReverseRelayLaunching,
    @unchecked Sendable
{
    let launches: AsyncStream<RecordedReverseRelayLaunch>
    let process = StubReverseRelayProcess()

    private let lock = NSLock()
    private var _launchCount = 0
    private var startupHandler: (@Sendable (any RemoteReverseRelayProcess) -> Void)?
    private var terminationHandler: (@Sendable (any RemoteReverseRelayProcess, String?) -> Void)?
    private let launchContinuation: AsyncStream<RecordedReverseRelayLaunch>.Continuation

    init() {
        (launches, launchContinuation) = AsyncStream.makeStream()
    }

    func launch(
        arguments: [String],
        environment: [String: String]?,
        startupMarker: String,
        startupHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess
        ) -> Void,
        terminationHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess,
            String?
        ) -> Void
    ) throws -> any RemoteReverseRelayProcess {
        let reverseArgumentIndex = try #require(arguments.firstIndex(of: "-R"))
        let reverseArgument = try #require(
            arguments.indices.contains(arguments.index(after: reverseArgumentIndex))
                ? arguments[arguments.index(after: reverseArgumentIndex)]
                : nil
        )
        let localRelayPort = try #require(
            Int(reverseArgument.split(separator: ":").last ?? "")
        )
        launchContinuation.yield(RecordedReverseRelayLaunch(
            arguments: arguments,
            localRelayPort: localRelayPort,
            startupMarker: startupMarker
        ))
        lock.withLock {
            _launchCount += 1
            self.startupHandler = startupHandler
            self.terminationHandler = terminationHandler
        }
        return process
    }

    var launchCount: Int {
        lock.withLock { _launchCount }
    }

    func emitStartupReady() {
        let handler = lock.withLock { startupHandler }
        handler?(process)
    }

    func emitTermination(detail: String?) {
        let handler = lock.withLock { terminationHandler }
        handler?(process, detail)
    }
}

/// Immutable fake process used by the injected launcher.
final class StubReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    let isRunning = true
    let terminationStatus: Int32 = 0

    func terminate() {}
}

final class ReverseRelayRecoveryHost: RemoteSessionHosting, @unchecked Sendable {
    let daemonStatuses: AsyncStream<WorkspaceRemoteDaemonStatus>
    private let daemonStatusContinuation: AsyncStream<WorkspaceRemoteDaemonStatus>.Continuation

    init() {
        (daemonStatuses, daemonStatusContinuation) = AsyncStream.makeStream()
    }

    func publishConnectionState(_ state: WorkspaceRemoteConnectionState, detail: String?) {}
    func publishDaemonStatus(_ status: WorkspaceRemoteDaemonStatus) {
        daemonStatusContinuation.yield(status)
    }
    func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {}
    func publishPortsSnapshot(detectedByPanel: [UUID: [Int]], detected: [Int]) {}
    func publishHeartbeat(count: Int, lastSeenAt: Date?) {}
    func publishBootstrapRemoteTTY(_ ttyName: String) {}
}
