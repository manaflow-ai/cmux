import Foundation
import Testing
import CmuxCore
import CmuxRemoteDaemon
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
        #expect(!RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "remote port forwarding failed for listen port 64045",
            relayPort: 64_044
        ))
        #expect(!RemoteSessionCoordinator.isReverseRelayPortBindingFailure(
            "Connection refused",
            relayPort: 64_044
        ))
    }

    @Test("Confirmed bind conflict exits the configured master once")
    func confirmedConflictExitsConfiguredMaster() async {
        let host = ReverseRelayRecoveryHost()
        let runner = RecordingProcessRunner { _ in
            RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr: "Control socket connect: No such file or directory"
            )
        }
        let coordinator = Self.makeCoordinator(host: host, runner: runner)

        let ignoredUnrelatedFailure = coordinator.queue.sync {
            coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "Connection refused",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-relay-startup-cancellation.sock"
            )
        }
        #expect(!ignoredUnrelatedFailure)
        #expect(runner.requests.isEmpty)

        let beganRecovery = coordinator.queue.sync {
            coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "Error: remote port forwarding failed for listen port 64044",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-relay-startup-cancellation.sock"
            )
        }
        #expect(beganRecovery)

        var statuses = host.daemonStatuses.makeAsyncIterator()
        let status = await statuses.next()
        #expect(status?.detail?.contains("retry in 2s") == true)

        let request = runner.requests.first
        #expect(request?.executable == "/usr/bin/ssh")
        #expect(request?.arguments.contains("-O") == true)
        #expect(request?.arguments.contains("exit") == true)
        #expect(request?.arguments.contains("-R") == false)
        #expect(request?.arguments.contains("StrictHostKeyChecking=accept-new") == true)
        #expect(request?.arguments.last == "user@example.test")

        let recoveryAttempted = coordinator.queue.sync {
            !coordinator.reverseRelayStartupPhase.isRecovering &&
                coordinator.reverseRelayRestartTask != nil
        }
        #expect(recoveryAttempted)
        let beganSecondRecovery = coordinator.queue.sync {
            coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "remote port forwarding failed for listen port 64044",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-relay-startup-cancellation.sock"
            )
        }
        #expect(!beganSecondRecovery)
        #expect(runner.requests.count == 1)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test(
        "Stop cancels conflicted-master exit without waiting on its timeout",
        .timeLimit(.minutes(1))
    )
    func stopCancelsConflictedMasterExit() async {
        let runner = BlockingConflictedMasterExitRunner()
        let coordinator = Self.makeCoordinator(runner: runner)

        coordinator.queue.async {
            _ = coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "remote port forwarding failed for listen port 64044",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-relay-startup-cancellation.sock"
            )
        }

        var started = runner.started.makeAsyncIterator()
        #expect(await started.next() != nil)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)

        var cancelled = runner.cancelled.makeAsyncIterator()
        #expect(await cancelled.next() != nil)
        let startupCleared = coordinator.queue.sync {
            !coordinator.reverseRelayStartupPhase.isRecovering &&
                coordinator.reverseRelayProcess == nil
        }
        #expect(startupCleared)
    }

    private static func makeCoordinator(
        host: any RemoteSessionHosting = NoopRemoteSessionHost(),
        runner: any RemoteSessionProcessRunning
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
            host: host,
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

private final class BlockingConflictedMasterExitRunner:
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
              request.arguments.contains("exit") else {
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        guard let operation else {
            throw BlockingConflictedMasterExitError.missingCancellationOperation
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

private enum BlockingConflictedMasterExitError: Error {
    case missingCancellationOperation
}

private final class ReverseRelayRecoveryHost: RemoteSessionHosting, @unchecked Sendable {
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
