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
    func confirmedConflictExitsConfiguredMaster() async throws {
        let host = ReverseRelayRecoveryHost()
        let runner = RecordingProcessRunner { _ in
            RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr: "Control socket connect: No such file or directory"
            )
        }
        let fixture = try Self.makeCoordinator(host: host, runner: runner)
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        let ignoredUnrelatedFailure = coordinator.queue.sync {
            coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "Connection refused",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: coordinator.configuration.localSocketPath ?? ""
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
                localSocketPath: coordinator.configuration.localSocketPath ?? ""
            )
        }
        #expect(beganRecovery)

        var statuses = host.daemonStatuses.makeAsyncIterator()
        let status = await statuses.next()
        #expect(status?.detail == String(
            localized: "remoteSession.reverseRelay.portUnavailableRetrying",
            defaultValue: "Remote SSH relay port unavailable; retrying in 2 seconds"
        ))

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
                localSocketPath: coordinator.configuration.localSocketPath ?? ""
            )
        }
        #expect(!beganSecondRecovery)
        #expect(runner.requests.count == 1)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Successful master exit retries the dedicated relay")
    func successfulMasterExitRetriesDedicatedRelay() async throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingReverseRelayLauncher()
        let relayPort = 64_046
        let fixture = try Self.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher,
            relayPort: relayPort
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        var launches = launcher.launches.makeAsyncIterator()
        coordinator.queue.async {
            coordinator.daemonReady = true
            _ = coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "Error: remote port forwarding failed for listen port \(relayPort)",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: relayPort,
                relayID: "relay-successful-recovery",
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: coordinator.configuration.localSocketPath ?? ""
            )
        }

        let launch = try #require(await launches.next())

        let recoveryRequest = runner.requests.first
        #expect(recoveryRequest?.arguments.contains("-O") == true)
        #expect(recoveryRequest?.arguments.contains("exit") == true)
        #expect(launch.arguments.starts(with: ["-N", "-T", "-S", "none"]))
        #expect(launch.arguments.contains("-R"))
        #expect(launch.arguments.contains(
            "127.0.0.1:\(relayPort):127.0.0.1:\(launch.localRelayPort)"
        ))
        #expect(!launch.arguments.contains(where: { $0.hasPrefix("ControlPath=") }))

        let retriedAfterRecovery = coordinator.queue.sync {
            coordinator.reverseRelayStartupPhase.allowsRelayLaunch &&
                coordinator.reverseRelayProcess === launcher.process
        }
        #expect(retriedAfterRecovery)
        #expect(RemoteSessionCoordinator.orphanedCMUXRemoteSSHPIDs(
            psOutput: "909 1 /usr/bin/ssh \(launch.arguments.joined(separator: " "))",
            destination: "user@example.test",
            relayPort: relayPort
        ) == [909])
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Stop cancels conflicted-master exit without waiting on its timeout")
    func stopCancelsConflictedMasterExit() async throws {
        let runner = BlockingConflictedMasterExitRunner()
        let fixture = try Self.makeCoordinator(runner: runner)
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        coordinator.queue.async {
            _ = coordinator.beginConflictedControlMasterExitIfNeededLocked(
                startupFailure: "remote port forwarding failed for listen port 64044",
                remotePath: "/tmp/cmuxd-remote",
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: coordinator.configuration.localSocketPath ?? ""
            )
        }

        var started = runner.started.makeAsyncIterator()
        #expect(await started.next() != nil)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)

        var cancelled = runner.cancelled.makeAsyncIterator()
        #expect(await cancelled.next() != nil)
        let startupCleared = coordinator.queue.sync {
            !coordinator.reverseRelayStartupPhase.isRecovering &&
                coordinator.reverseRelayStartupPhase.allowsRelayLaunch &&
                coordinator.reverseRelayProcess == nil
        }
        #expect(startupCleared)
    }

    private static func makeCoordinator(
        host: any RemoteSessionHosting = NoopRemoteSessionHost(),
        runner: any RemoteSessionProcessRunning,
        reverseRelayLauncher: any RemoteReverseRelayLaunching = RemoteReverseRelayLauncher(),
        relayPort: Int = 64_044
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
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-startup-cancellation",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: scratchDirectory.appendingPathComponent("relay.sock").path,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
        let coordinator = RemoteSessionCoordinator(
            host: host,
            configuration: configuration,
            proxyBroker: SSHOverrideUnusedRemoteProxyBroker(),
            connectionBroker: NativeSSHConnectionBroker(),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: scratchDirectory
            ),
            processRunner: runner,
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
                suspendedDetailFormat: "%@"
            )
        )
        return (coordinator, scratchDirectory)
    }
}

private struct RecordedReverseRelayLaunch: Sendable {
    let arguments: [String]
    let localRelayPort: Int
}

/// Immutable recorder; `AsyncStream.Continuation` owns synchronized delivery.
private final class RecordingReverseRelayLauncher:
    RemoteReverseRelayLaunching,
    @unchecked Sendable
{
    let launches: AsyncStream<RecordedReverseRelayLaunch>
    let process = StubReverseRelayProcess()

    private let launchContinuation: AsyncStream<RecordedReverseRelayLaunch>.Continuation

    init() {
        (launches, launchContinuation) = AsyncStream.makeStream()
    }

    func launch(
        arguments: [String],
        environment: [String: String]?,
        terminationHandler: @escaping @Sendable (any RemoteReverseRelayProcess) -> Void
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
            localRelayPort: localRelayPort
        ))
        return process
    }
}

/// Immutable fake process; the pipe is never concurrently read or written.
private final class StubReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    let stderrPipe = Pipe()
    let isRunning = true
    let terminationStatus: Int32 = 0

    func startupFailureDetail(gracePeriod: TimeInterval) -> String? {
        nil
    }

    func terminate() {}
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
