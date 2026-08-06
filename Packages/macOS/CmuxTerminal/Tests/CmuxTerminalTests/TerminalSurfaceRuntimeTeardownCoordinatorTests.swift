import Dispatch
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

@Suite struct TerminalSurfaceRuntimeTeardownCoordinatorTests {
    @Test func ticketDistinguishesDeadlineFromEventualCompletion() async {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)

        #expect(await ticket.wait(timeout: .zero) == false)

        await completion.finish()

        #expect(await ticket.wait(timeout: nil))
    }

    @Test func enqueuedTeardownInvokesInjectedFreeWithTheSamePointer() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        let ticket = coordinator.enqueueRuntimeTeardown(
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
        #expect(await ticket.wait(timeout: nil))
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

    @Test func closeNativeFreesNeverOverlap() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let firstFreeStarted = AsyncStream<Void>.makeStream()
        let releaseFirstFree = DispatchSemaphore(value: 0)
        let lifecycle = TeardownLifetimeRecorder()
        defer {
            releaseFirstFree.signal()
            firstFreeStarted.continuation.finish()
        }

        let firstTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.firstClose",
            surface: surfaces[0],
            callbackContext: nil,
            freeSurface: { _ in
                lifecycle.record("first.started")
                firstFreeStarted.continuation.yield()
                _ = releaseFirstFree.wait(timeout: .distantFuture)
                lifecycle.record("first.completed")
            }
        )
        var firstFreeIterator = firstFreeStarted.stream.makeAsyncIterator()
        _ = await firstFreeIterator.next()

        let secondTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.secondClose",
            surface: surfaces[1],
            callbackContext: nil,
            freeSurface: { _ in lifecycle.record("second.completed") }
        )

        releaseFirstFree.signal()
        #expect(await firstTicket.wait(timeout: nil))
        #expect(await secondTicket.wait(timeout: nil))
        #expect(lifecycle.snapshot() == [
            "first.started",
            "first.completed",
            "second.completed",
        ])
    }

    @Test func nativeCreationWaitsForEarlierTeardown() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let freeStarted = AsyncStream<Void>.makeStream()
        let releaseFree = DispatchSemaphore(value: 0)
        let lifecycle = TeardownLifetimeRecorder()
        defer {
            releaseFree.signal()
            freeStarted.continuation.finish()
        }

        let teardownTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.creationWaitsForTeardown",
            surface: surface,
            callbackContext: nil,
            freeSurface: { _ in
                lifecycle.record("teardown.started")
                freeStarted.continuation.yield()
                _ = releaseFree.wait(timeout: .distantFuture)
                lifecycle.record("teardown.completed")
            }
        )
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()

        let creationTicket = coordinator.enqueueRuntimeCreation(
            id: UUID(),
            reason: "test.afterTeardown"
        ) {
            lifecycle.record("creation.completed")
        }

        releaseFree.signal()
        #expect(await teardownTicket.wait(timeout: nil))
        #expect(await creationTicket.wait())
        #expect(lifecycle.snapshot() == [
            "teardown.started",
            "teardown.completed",
            "creation.completed",
        ])
    }

    @Test func backToBackCreationAndTeardownPreserveSubmissionOrder() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifecycle = TeardownLifetimeRecorder()

        let creationTicket = coordinator.enqueueRuntimeCreation(
            id: UUID(),
            reason: "test.backToBackCreation"
        ) {
            lifecycle.record("creation")
        }
        let teardownTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.backToBackTeardown",
            surface: surface,
            callbackContext: nil,
            freeSurface: { _ in lifecycle.record("teardown") }
        )

        #expect(await creationTicket.wait())
        #expect(await teardownTicket.wait(timeout: nil))
        #expect(lifecycle.snapshot() == ["creation", "teardown"])
    }

    @Test func nativeTeardownWaitsForEarlierCreation() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let creationStarted = AsyncStream<Void>.makeStream()
        let releaseCreation = RuntimeOperationGate()
        let lifecycle = TeardownLifetimeRecorder()
        defer {
            creationStarted.continuation.finish()
            Task { await releaseCreation.open() }
        }

        let creationTicket = coordinator.enqueueRuntimeCreation(
            id: UUID(),
            reason: "test.creation"
        ) {
            lifecycle.record("creation.started")
            creationStarted.continuation.yield()
            await releaseCreation.wait()
            lifecycle.record("creation.completed")
        }
        var creationStartedIterator =
            creationStarted.stream.makeAsyncIterator()
        _ = await creationStartedIterator.next()

        let teardownTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.afterCreation",
            surface: surface,
            callbackContext: nil,
            freeSurface: { _ in
                lifecycle.record("teardown.completed")
            }
        )

        await releaseCreation.open()
        #expect(await creationTicket.wait())
        #expect(await teardownTicket.wait(timeout: nil))
        #expect(lifecycle.snapshot() == [
            "creation.started",
            "creation.completed",
            "teardown.completed",
        ])
    }

    @Test func queuedCloseNativeFreesEventuallyDrain() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let stuckFreeStarted = AsyncStream<Void>.makeStream()
        let releaseStuckFree = DispatchSemaphore(value: 0)
        let freedSurfaceBits = OSAllocatedUnfairLock(initialState: Set<UInt>())
        defer {
            releaseStuckFree.signal()
            stuckFreeStarted.continuation.finish()
        }

        let stuckTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.stuckClose",
            surface: surfaces[0],
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                freedSurfaceBits.withLock {
                    _ = $0.insert(bits)
                }
                stuckFreeStarted.continuation.yield()
                _ = releaseStuckFree.wait(timeout: .distantFuture)
            }
        )
        var stuckFreeIterator = stuckFreeStarted.stream.makeAsyncIterator()
        _ = await stuckFreeIterator.next()

        let laterTickets = surfaces.dropFirst().map { surface in
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.laterClose",
                surface: surface,
                callbackContext: nil,
                freeSurface: { pointer in
                    let bits = UInt(bitPattern: pointer)
                    freedSurfaceBits.withLock {
                        _ = $0.insert(bits)
                    }
                }
            )
        }

        #expect(await stuckTicket.wait(timeout: .zero) == false)

        releaseStuckFree.signal()
        #expect(await stuckTicket.wait(timeout: nil))
        for ticket in laterTickets {
            try #require(
                await ticket.wait(timeout: nil),
                "a queued native free did not drain"
            )
        }
        #expect(
            freedSurfaceBits.withLock { $0 } ==
                Set(surfaces.map { UInt(bitPattern: $0) })
        )
    }

    @Test func nativeFreesAcrossHibernationAndCloseNeverOverlap() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let isolatedSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let queuedIsolatedSurface = UnsafeMutableRawPointer.allocate(
            byteCount: 8,
            alignment: 8
        )
        let closeSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            isolatedSurface.deallocate()
            queuedIsolatedSurface.deallocate()
            closeSurface.deallocate()
        }
        let isolatedFreeStarted = AsyncStream<Void>.makeStream()
        let releaseIsolatedFree = DispatchSemaphore(value: 0)
        let secondIsolatedFreeCount = OSAllocatedUnfairLock(initialState: 0)
        let closeFreeCount = OSAllocatedUnfairLock(initialState: 0)
        defer {
            releaseIsolatedFree.signal()
            isolatedFreeStarted.continuation.finish()
        }

        let isolatedReservation = try #require(
            await coordinator.reserveHibernationTeardown()
        )
        let isolatedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.isolatedHibernation",
            surface: isolatedSurface,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            hibernationReservation: isolatedReservation,
            freeSurface: { _ in
                isolatedFreeStarted.continuation.yield()
                _ = releaseIsolatedFree.wait(timeout: .distantFuture)
            }
        )
        var isolatedFreeIterator = isolatedFreeStarted.stream.makeAsyncIterator()
        _ = await isolatedFreeIterator.next()

        let secondReservation = try #require(
            await coordinator.reserveHibernationTeardown()
        )
        #expect(await coordinator.reserveHibernationTeardown() == nil)
        let secondIsolatedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.secondIsolatedHibernation",
            surface: queuedIsolatedSurface,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            hibernationReservation: secondReservation,
            freeSurface: { _ in
                secondIsolatedFreeCount.withLock { $0 += 1 }
            }
        )
        let closeTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.close",
            surface: closeSurface,
            callbackContext: nil,
            freeSurface: { _ in
                closeFreeCount.withLock { $0 += 1 }
            }
        )

        #expect(closeFreeCount.withLock { $0 } == 0)
        #expect(await isolatedTicket.wait(timeout: .zero) == false)
        #expect(secondIsolatedFreeCount.withLock { $0 } == 0)
        #expect(await coordinator.reserveHibernationTeardown() == nil)

        releaseIsolatedFree.signal()
        #expect(await isolatedTicket.wait(timeout: nil))
        #expect(await secondIsolatedTicket.wait(timeout: nil))
        #expect(await closeTicket.wait(timeout: nil))
        #expect(secondIsolatedFreeCount.withLock { $0 } == 1)
        #expect(closeFreeCount.withLock { $0 } == 1)

        let nextReservation = try #require(
            await coordinator.reserveHibernationTeardown()
        )
        await coordinator.cancelHibernationTeardown(nextReservation)
    }

    @Test func staleIsolatedReservationFallsBackToSerializedFree() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let freeCount = OSAllocatedUnfairLock(initialState: 0)
        let staleReservation = try #require(
            await coordinator.reserveHibernationTeardown()
        )
        await coordinator.cancelHibernationTeardown(staleReservation)

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.staleIsolatedReservation",
            surface: surface,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            hibernationReservation: staleReservation,
            freeSurface: { _ in
                freeCount.withLock { $0 += 1 }
            }
        )

        #expect(await ticket.wait(timeout: nil))
        #expect(freeCount.withLock { $0 } == 1)
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
