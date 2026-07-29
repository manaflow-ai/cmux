import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Inherited ControlMaster reap")
struct RemoteSessionInheritedMasterReapTests {
    @Test("Owned persistent relay exits its inherited master before retrying")
    func ownedPersistentRelayExitsInheritedMaster() async throws {
        let runner = InheritedMasterReapProcessRunner()
        let launcher = RecordingReverseRelayLauncher()
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                reverseRelayLauncher: launcher,
                persistentDaemonSlot: "ssh-persistent-slot",
                clock: clock
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }
        var requests = runner.requestStream.makeAsyncIterator()

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        let initialRequests = runner.requests
        try #require(!initialRequests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(initialRequests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }.count == 1)

        var exitRequest: RemoteProcessRequest?
        while let request = await requests.next() {
            if Self.isControlCommand("exit", in: request.arguments) {
                exitRequest = request
                break
            }
        }
        let reapingRequest = try #require(exitRequest)
        #expect(
            reapingRequest.arguments.contains(
                "ControlPath=\(ResolvedControlPathFixture.path)"
            )
        )
        #expect(!reapingRequest.arguments.contains("-R"))
        #expect(launcher.launchCount == 0)
        #expect(await clock.nextRequestedDelay() == 2_000)
        #expect(runner.requests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }.count == 1)

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}

private final class InheritedMasterReapProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    let requestStream: AsyncStream<RemoteProcessRequest>

    // lint:allow lock - synchronous test requests append and snapshot only.
    private let lock = NSLock()
    private var recordedRequests: [RemoteProcessRequest] = []
    private let requestContinuation:
        AsyncStream<RemoteProcessRequest>.Continuation

    init() {
        (requestStream, requestContinuation) = AsyncStream.makeStream()
    }

    var requests: [RemoteProcessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            recordedRequests.append(request)
        }
        requestContinuation.yield(request)
        if Self.isControlCommand("forward", in: request.arguments) {
            return RemoteCommandResult(
                status: 255,
                stdout: "",
                stderr:
                    "remote port forwarding failed for listen port 64044"
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }
}
