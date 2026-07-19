import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@Suite("Backend-only renderer frame release lane")
struct BackendOnlyRendererFrameReleaseLaneTests {
    @Test("one lifetime drain forwards exact releases in FIFO order")
    func oneLifetimeDrainIsSerialAndOrdered() async throws {
        let sender = ControlledReleaseSender()
        let lane = BackendOnlyRendererFrameReleaseLane(
            normalCapacity: 8,
            recoveryCapacity: 2,
            send: sender.send
        )
        let releases = (1 ... 5).map(makeRelease)

        for release in releases {
            #expect(lane.enqueue(release, priority: .normal) == .accepted)
        }
        await sender.waitUntilStarted(count: 1)
        for count in 1 ... releases.count {
            await sender.resumeNext(result: true)
            if count < releases.count {
                await sender.waitUntilStarted(count: count + 1)
            }
        }
        await lane.waitUntilIdle()

        #expect(await sender.startedSnapshot() == releases)
        #expect(await sender.maximumConcurrentSendCount == 1)
        #expect(lane.metrics().workerStarts == 1)
        #expect(lane.metrics().sent == 5)
        #expect(lane.metrics().outstanding == 0)
        await lane.stop()
    }

    @Test("recovery reserve cannot be consumed by ordinary GPU completions")
    func recoveryCapacityIsReserved() async {
        let sender = ControlledReleaseSender()
        let overflows = FailureRecorder()
        let lane = BackendOnlyRendererFrameReleaseLane(
            normalCapacity: 2,
            recoveryCapacity: 1,
            send: sender.send,
            onFailure: overflows.record
        )

        #expect(lane.enqueue(makeRelease(1), priority: .normal) == .accepted)
        await sender.waitUntilStarted(count: 1)
        #expect(lane.enqueue(makeRelease(2), priority: .normal) == .accepted)
        #expect(lane.enqueue(makeRelease(3), priority: .normal) == .capacityExceeded)
        #expect(lane.enqueue(makeRelease(4), priority: .recovery) == .accepted)
        #expect(lane.enqueue(makeRelease(5), priority: .recovery) == .capacityExceeded)
        #expect(overflows.snapshot() == [.capacityExceeded, .capacityExceeded])
        #expect(lane.metrics().maximumOutstanding == 3)
        #expect(lane.metrics().capacityFailures == 2)

        await sender.resumeNext(result: true)
        await sender.waitUntilStarted(count: 2)
        await sender.resumeNext(result: true)
        await sender.waitUntilStarted(count: 3)
        await sender.resumeNext(result: true)
        await lane.waitUntilIdle()
        #expect(await sender.startedSnapshot().map(\.frameSequence) == [1, 2, 4])
        await lane.stop()
    }

    @Test("stop rejects new work and waits for every accepted release")
    func stopFlushesAcceptedWorkExactlyOnce() async {
        let sender = ControlledReleaseSender()
        let lane = BackendOnlyRendererFrameReleaseLane(
            normalCapacity: 4,
            recoveryCapacity: 1,
            send: sender.send
        )
        #expect(lane.enqueue(makeRelease(1), priority: .normal) == .accepted)
        #expect(lane.enqueue(makeRelease(2), priority: .recovery) == .accepted)
        await sender.waitUntilStarted(count: 1)

        let stop = Task { await lane.stop() }
        #expect(lane.enqueue(makeRelease(3), priority: .recovery) == .stopped)
        #expect(!stop.isCancelled)
        await sender.resumeNext(result: true)
        await sender.waitUntilStarted(count: 2)
        await sender.resumeNext(result: true)
        await stop.value

        #expect(await sender.startedSnapshot().map(\.frameSequence) == [1, 2])
        #expect(lane.metrics().sent == 2)
        #expect(lane.metrics().rejectedAfterStop == 1)
        await lane.stop()
        #expect(await sender.startedSnapshot().count == 2)
    }

    @Test("one failed send reports failure and the drain continues")
    func sendFailureDoesNotStrandLaterReleases() async {
        let sender = ControlledReleaseSender()
        let failures = FailureRecorder()
        let lane = BackendOnlyRendererFrameReleaseLane(
            normalCapacity: 4,
            recoveryCapacity: 1,
            send: sender.send,
            onFailure: failures.record
        )
        #expect(lane.enqueue(makeRelease(1), priority: .normal) == .accepted)
        #expect(lane.enqueue(makeRelease(2), priority: .normal) == .accepted)
        await sender.waitUntilStarted(count: 1)
        await sender.resumeNext(result: false)
        await sender.waitUntilStarted(count: 2)
        await sender.resumeNext(result: true)
        await lane.waitUntilIdle()

        #expect(failures.snapshot() == [.sendFailed])
        #expect(lane.metrics().sendFailures == 1)
        #expect(lane.metrics().sent == 1)
        #expect(lane.metrics().outstanding == 0)
        await lane.stop()
    }
}

private actor ControlledReleaseSender {
    private var started: [BackendRendererFrameRelease] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var startWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var concurrentSendCount = 0
    private(set) var maximumConcurrentSendCount = 0

    func send(_ release: BackendRendererFrameRelease) async -> Bool {
        concurrentSendCount += 1
        maximumConcurrentSendCount = max(
            maximumConcurrentSendCount,
            concurrentSendCount
        )
        started.append(release)
        resumeStartWaiters()
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        concurrentSendCount -= 1
        return result
    }

    func waitUntilStarted(count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func resumeNext(result: Bool) {
        continuations.removeFirst().resume(returning: result)
    }

    func startedSnapshot() -> [BackendRendererFrameRelease] { started }

    private func resumeStartWaiters() {
        var retained: [
            (count: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in startWaiters {
            if started.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                retained.append(waiter)
            }
        }
        startWaiters = retained
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [BackendOnlyRendererFrameReleaseLaneFailure] = []

    func record(_ failure: BackendOnlyRendererFrameReleaseLaneFailure) {
        lock.lock()
        failures.append(failure)
        lock.unlock()
    }

    func snapshot() -> [BackendOnlyRendererFrameReleaseLaneFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

private func makeRelease(_ frameSequence: Int) -> BackendRendererFrameRelease {
    BackendRendererFrameRelease(
        daemonInstanceID: DaemonInstanceID(rawValue: releaseUUID(1)),
        rendererEpoch: 2,
        terminalID: SurfaceID(rawValue: releaseUUID(3)),
        terminalEpoch: 4,
        terminalSequence: 5,
        presentationID: PresentationID(rawValue: releaseUUID(6)),
        presentationGeneration: 7,
        frameSequence: UInt64(frameSequence),
        surfaceID: UInt32(frameSequence)
    )
}

private func releaseUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "AE1EA5E0-0000-0000-0000-%012llX", value))!
}
