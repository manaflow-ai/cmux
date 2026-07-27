import Foundation
import os
import Testing
@testable import CmuxTerminal

/// Records freed pointers behind an actor so the @Sendable free closures can
/// report back across the worker hop.
private actor FreedSurfaceRecorder {
    /// Freed pointers as Sendable bit patterns.
    private(set) var freed: [UInt] = []
    private var continuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ pointerBits: UInt) {
        freed.append(pointerBits)
        let count = freed.count
        for waiter in continuations.removeValue(forKey: count) ?? [] {
            waiter.resume()
        }
    }

    /// Suspends until `count` frees have been recorded.
    func waitForFreeCount(_ count: Int) async {
        guard freed.count < count else { return }
        await withCheckedContinuation { continuation in
            continuations[count, default: []].append(continuation)
        }
    }
}

private final class TeardownLifetimeRecorder: @unchecked Sendable {
    let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let recordedEvents = OSAllocatedUnfairLock(initialState: [String]())

    init() {
        (events, continuation) = AsyncStream.makeStream(of: String.self)
    }

    func record(_ event: String) {
        recordedEvents.withLock { $0.append(event) }
        continuation.yield(event)
    }

    func snapshot() -> [String] {
        recordedEvents.withLock { $0 }
    }
}

private final class LifetimeRecordingByteTeeLease: TerminalByteTeeLease, @unchecked Sendable {
    private let recorder: TeardownLifetimeRecorder

    init(recorder: TeardownLifetimeRecorder) {
        self.recorder = recorder
    }

    func release() {
        recorder.record("tee.release")
    }
}

private final class BlockingNativeFreeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var observedMainThread: Bool?

    var startedOnMainThread: Bool? {
        lock.withLock { observedMainThread }
    }

    func block() {
        let waiters = lock.withLock {
            started = true
            observedMainThread = Thread.isMainThread
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
        _ = releaseSemaphore.wait(timeout: .now() + 15)
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if started {
                    return true
                }
                startWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

@Suite struct TerminalSurfaceRuntimeTeardownCoordinatorTests {
    @Test func enqueuedTeardownInvokesInjectedFreeWithTheSamePointer() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test",
            surface: surface,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )

        await recorder.waitForFreeCount(1)
        #expect(await recorder.freed == [UInt(bitPattern: surface)])
    }

    @Test func teardownsForMultipleSurfacesAllFree() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }

        for surface in surfaces {
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.batch",
                surface: surface,
                callbackContext: nil,
                freeSurface: { pointer in
                    let bits = UInt(bitPattern: pointer)
                    Task { await recorder.record(bits) }
                }
            )
        }

        await recorder.waitForFreeCount(surfaces.count)
        #expect(await Set(recorder.freed) == Set(surfaces.map { UInt(bitPattern: $0) }))
    }

    @Test func blockedNativeFreeStaysOffMainAndSerializesFollowingFree() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = TeardownLifetimeRecorder()
        let gate = BlockingNativeFreeGate()
        let firstSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let secondSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            gate.release()
            firstSurface.deallocate()
            secondSurface.deallocate()
        }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.blockedFirst",
            surface: firstSurface,
            callbackContext: nil,
            freeSurface: { _ in
                gate.block()
                recorder.record("first.free")
            }
        )
        await gate.waitUntilBlocked()

        let ranOnMainThread = gate.startedOnMainThread
        #expect(ranOnMainThread == false, "native free must run on the utility teardown worker")
        guard ranOnMainThread == false else {
            gate.release()
            return
        }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.queuedSecond",
            surface: secondSurface,
            callbackContext: nil,
            freeSurface: { _ in
                recorder.record("second.free")
            }
        )

        let mainActorProbeStarted = ContinuousClock.now
        let mainActorResponded = await MainActor.run { Thread.isMainThread }
        let mainActorProbeDuration = ContinuousClock.now - mainActorProbeStarted
        #expect(mainActorResponded)
        #expect(
            mainActorProbeDuration < .milliseconds(500),
            "a blocked native free must not delay main-actor work"
        )

        #expect(
            recorder.snapshot().isEmpty,
            "the explicitly blocked first free must keep the following free serialized"
        )

        gate.release()
        for await event in recorder.events where event == "second.free" {
            break
        }
        #expect(recorder.snapshot() == ["first.free", "second.free"])
    }

    @Test func byteTeeCallbackOwnerIsReleasedOnlyAfterNativeFreeReturns() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = TeardownLifetimeRecorder()
        let lease = LifetimeRecordingByteTeeLease(recorder: recorder)
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.teeLifetime",
            surface: surface,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: lease,
            freeSurface: { _ in
                recorder.record("surface.free")
            }
        )

        for await event in recorder.events where event == "tee.release" {
            break
        }
        #expect(recorder.snapshot() == ["surface.free", "tee.release"])
    }
}
