import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

actor CountingOrphanProcessSnapshotCapturer: RemoteOrphanProcessSnapshotCapturing {
    private let snapshots: [RemoteOrphanProcessSnapshot]
    private(set) var captureCount = 0

    init(snapshots: [RemoteOrphanProcessSnapshot]) {
        self.snapshots = snapshots
    }

    func capture() -> [RemoteOrphanProcessSnapshot] {
        captureCount += 1
        return snapshots
    }
}

actor SuspendedOrphanProcessSnapshotCapturer: RemoteOrphanProcessSnapshotCapturing {
    private let snapshots: [RemoteOrphanProcessSnapshot]
    private var captureCount = 0
    private var captureContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(snapshots: [RemoteOrphanProcessSnapshot]) {
        self.snapshots = snapshots
    }

    func capture() async -> [RemoteOrphanProcessSnapshot] {
        captureCount += 1
        resumeSatisfiedCountWaiters()
        await withCheckedContinuation { continuation in
            captureContinuations.append(continuation)
        }
        return snapshots
    }

    func waitForCaptureCount(_ expected: Int) async {
        guard captureCount < expected else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
        }
    }

    func releaseAll() {
        let continuations = captureContinuations
        captureContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeSatisfiedCountWaiters() {
        let satisfied = countWaiters.filter { captureCount >= $0.count }
        countWaiters.removeAll { captureCount >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}

actor RecordedSignals {
    private var recordedPIDs: [Int] = []

    var pids: [Int] { recordedPIDs.sorted() }

    func record(_ pid: Int, _ signal: Int32) -> Int32 {
        guard signal == SIGTERM else { return -1 }
        recordedPIDs.append(pid)
        return 0
    }
}

struct OrphanReapRequest: Sendable, Equatable {
    let destination: String
    let relayPort: Int?
    let persistentDaemonSlot: String?
}

actor RecordingOrphanedProcessReaper: RemoteOrphanedProcessReaping {
    private var requests: [OrphanReapRequest] = []
    private var nextRequestContinuation: CheckedContinuation<OrphanReapRequest, Never>?

    func reap(destination: String, relayPort: Int?, persistentDaemonSlot: String?) {
        let request = OrphanReapRequest(
            destination: destination,
            relayPort: relayPort,
            persistentDaemonSlot: persistentDaemonSlot
        )
        if let nextRequestContinuation {
            self.nextRequestContinuation = nil
            nextRequestContinuation.resume(returning: request)
        } else {
            requests.append(request)
        }
    }

    func nextRequest() async -> OrphanReapRequest {
        if !requests.isEmpty {
            return requests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            nextRequestContinuation = continuation
        }
    }
}

final class CountingThrowingRemoteSessionProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    struct ExpectedFailure: Error {}

    private let lock = NSLock()
    private var _runCount = 0

    var runCount: Int { lock.withLock { _runCount } }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock { _runCount += 1 }
        throw ExpectedFailure()
    }
}

struct ThrowingRemoteSessionProcessRunner: RemoteSessionProcessRunning {
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        throw CountingThrowingRemoteSessionProcessRunner.ExpectedFailure()
    }
}

actor SuspendedOrphanedProcessReaper: RemoteOrphanedProcessReaping {
    private var requestCount = 0
    private var requestContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func reap(destination: String, relayPort: Int?, persistentDaemonSlot: String?) async {
        requestCount += 1
        resumeSatisfiedCountWaiters()
        await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
        }
    }

    func releaseAll() {
        let continuations = requestContinuations
        requestContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeSatisfiedCountWaiters() {
        let satisfied = countWaiters.filter { requestCount >= $0.count }
        countWaiters.removeAll { requestCount >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}
