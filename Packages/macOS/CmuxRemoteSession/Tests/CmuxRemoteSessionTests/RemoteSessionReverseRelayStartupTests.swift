import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
@testable import CmuxRemoteSession
@testable import CmuxRemoteWorkspace

@Suite("Reverse relay startup lifecycle")
struct RemoteSessionReverseRelayStartupTests {
    @Test(
        "Stop cancels inherited-forward cleanup without waiting on its timeout",
        .timeLimit(.minutes(1))
    )
    func stopCancelsInheritedForwardCleanup() async {
        let runner = BlockingInheritedForwardCancellationRunner()
        let coordinator = Self.makeCoordinator(runner: runner)

        coordinator.queue.async {
            coordinator.daemonReady = true
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        var started = runner.started.makeAsyncIterator()
        #expect(await started.next() != nil)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)

        var cancelled = runner.cancelled.makeAsyncIterator()
        #expect(await cancelled.next() != nil)
        let startupCleared = coordinator.queue.sync {
            coordinator.reverseRelayStartupPhase.isIdle &&
                coordinator.reverseRelayProcess == nil
        }
        #expect(startupCleared)
    }

    private static func makeCoordinator(
        runner: BlockingInheritedForwardCancellationRunner
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: 64_044,
            relayID: "relay-startup-cancellation",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-relay-startup-cancellation.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
        return RemoteSessionCoordinator(
            host: NoopRemoteSessionHost(),
            configuration: configuration,
            proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: SSHOverrideNoopReachabilityProbe(),
            relayCommandRewriter: SSHOverridePassthroughRelayCommandRewriter(),
            buildInfo: SSHOverrideStubBuildInfo(),
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

private final class BlockingInheritedForwardCancellationRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let started: AsyncStream<Void>
    let cancelled: AsyncStream<Void>

    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledContinuation: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
        (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        guard request.arguments.contains("-O"),
              request.arguments.contains("cancel") else {
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        guard let operation else {
            throw BlockingInheritedForwardCancellationError.missingCancellationOperation
        }

        try operation.throwIfCancelled()
        operation.installCancellationHandler { [cancelledContinuation, release] in
            cancelledContinuation.yield()
            release.signal()
        }
        defer { operation.clearCancellationHandler() }
        startedContinuation.yield()
        release.wait()
        throw operation.cancellationError
    }
}

private enum BlockingInheritedForwardCancellationError: Error {
    case missingCancellationOperation
}
