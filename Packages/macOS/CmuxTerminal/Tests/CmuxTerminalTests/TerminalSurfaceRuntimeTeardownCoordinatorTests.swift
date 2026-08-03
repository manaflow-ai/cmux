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

private func requireTeardownTicket(
    _ ticket: TerminalSurfaceRuntimeTeardownTicket?
) throws -> TerminalSurfaceRuntimeTeardownTicket {
    try #require(ticket)
}

@Suite struct TerminalSurfaceRuntimeTeardownCoordinatorTests {
    @Test func ticketDistinguishesDeadlineFromEventualCompletion() async {
        let completion = TerminalSurfaceRuntimeTeardownCompletion()
        let ticket = TerminalSurfaceRuntimeTeardownTicket(completion: completion)

        #expect(await ticket.wait(timeout: .zero) == false)

        await completion.finish()

        #expect(await ticket.wait(timeout: nil))
    }

    @Test func enqueuedTeardownInvokesInjectedFreeWithTheSamePointer() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        let ticket = try requireTeardownTicket(
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
        )

        await recorder.waitForFreeCount(1)
        #expect(await ticket.wait(timeout: .seconds(1)))
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

    @Test func oneStuckCloseDoesNotStrandLaterCloses() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let firstFreeStarted = AsyncStream<Void>.makeStream()
        let releaseFirstFree = DispatchSemaphore(value: 0)
        defer {
            releaseFirstFree.signal()
            firstFreeStarted.continuation.finish()
        }

        let firstTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.stuckClose",
                surface: surfaces[0],
                callbackContext: nil,
                freeSurface: { _ in
                    firstFreeStarted.continuation.yield()
                    releaseFirstFree.wait()
                }
            )
        )
        var firstFreeIterator = firstFreeStarted.stream.makeAsyncIterator()
        _ = await firstFreeIterator.next()

        let secondTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.closeAfterStuckClose",
                surface: surfaces[1],
                callbackContext: nil,
                freeSurface: { _ in }
            )
        )
        let thirdTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.secondCloseAfterStuckClose",
                surface: surfaces[2],
                callbackContext: nil,
                freeSurface: { _ in }
            )
        )

        let secondCompleted = await secondTicket.wait(timeout: .seconds(1))
        let thirdCompleted = await thirdTicket.wait(timeout: .seconds(1))
        releaseFirstFree.signal()

        #expect(secondCompleted, "one stuck native free stranded the next explicit close")
        #expect(thirdCompleted, "one stuck native free stranded the remaining close worker")
        #expect(await firstTicket.wait(timeout: .seconds(1)))
    }

    @Test func twoStuckClosesBoundAdmissionUntilAWorkerRecovers() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            closeTeardownTimeout: .milliseconds(50),
            maximumRuntimeSurfaceOwnerCount: 4
        )
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let freeStarted = AsyncStream<Void>.makeStream()
        let releaseFrees = DispatchSemaphore(value: 0)
        defer {
            releaseFrees.signal()
            releaseFrees.signal()
            freeStarted.continuation.finish()
        }

        let firstTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.firstStuckClose",
                surface: surfaces[0],
                callbackContext: nil,
                freeSurface: { _ in
                    freeStarted.continuation.yield()
                    releaseFrees.wait()
                }
            )
        )
        let secondTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.secondStuckClose",
                surface: surfaces[1],
                callbackContext: nil,
                freeSurface: { _ in
                    freeStarted.continuation.yield()
                    releaseFrees.wait()
                }
            )
        )
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()
        _ = await freeStartedIterator.next()

        let degradationDeadline = ContinuousClock.now + .seconds(1)
        while await !coordinator.debugCloseTeardownDegraded,
              ContinuousClock.now < degradationDeadline {
            await Task.yield()
        }
        #expect(await coordinator.debugCloseTeardownDegraded)
        #expect(await coordinator.debugPendingTeardownCount == 2)
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 2)

        let rejectedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.closeAfterBothWorkersStalled",
            surface: surfaces[2],
            callbackContext: nil,
            freeSurface: { _ in }
        )
        #expect(rejectedTicket == nil)
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 2)

        releaseFrees.signal()
        releaseFrees.signal()
        #expect(await firstTicket.wait(timeout: .seconds(1)))
        #expect(await secondTicket.wait(timeout: .seconds(1)))
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)

        let recoveryDeadline = ContinuousClock.now + .seconds(1)
        while await coordinator.debugCloseTeardownDegraded,
              ContinuousClock.now < recoveryDeadline {
            await Task.yield()
        }
        #expect(await !coordinator.debugCloseTeardownDegraded)
        let recoveredTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.closeAfterWorkerRecovery",
                surface: surfaces[2],
                callbackContext: nil,
                freeSurface: { _ in }
            )
        )
        #expect(await recoveredTicket.wait(timeout: .seconds(1)))
    }

    @MainActor
    @Test func staleRecoveryHeadDoesNotStrandTheNextWaiter() async throws {
        let admission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: 2
        )
        let firstOwner = try #require(admission.reserve())
        let secondOwner = try #require(admission.reserve())
        var staleProbe: NSObject? = NSObject()
        weak let releasedProbe = staleProbe
        let staleRecoveryID = UUID()
        let nextRecoveryID = UUID()
        var staleRecoveryDeclined = false
        var nextRecoveryRan = false

        let staleReservation = admission.reserve(
            recoveryID: staleRecoveryID,
            onRecovery: { [weak staleProbe] reservation in
                guard staleProbe != nil else {
                    staleRecoveryDeclined = true
                    admission.release(reservation)
                    return
                }
                admission.release(reservation)
            }
        )
        let nextReservation = admission.reserve(
            recoveryID: nextRecoveryID,
            onRecovery: { reservation in
                nextRecoveryRan = true
                admission.release(reservation)
            }
        )
        #expect(staleReservation == nil)
        #expect(nextReservation == nil)

        admission.release(firstOwner)
        staleProbe = nil
        #expect(releasedProbe == nil)
        for _ in 0..<100 where !nextRecoveryRan {
            await Task.yield()
        }

        #expect(staleRecoveryDeclined)
        #expect(
            nextRecoveryRan,
            "a stale dequeued recovery callback stranded the next waiter despite free capacity"
        )
        admission.cancelRecovery(nextRecoveryID)
        admission.release(secondOwner)
    }

    @MainActor
    @Test func recoveryGrantsOnlyOneWaiterAtATime() async {
        let admission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: 4
        )
        admission.setCloseTeardownDegraded(true)
        var recoveredCount = 0

        for _ in 0..<3 {
            let reservation = admission.reserve(
                recoveryID: UUID(),
                onRecovery: { reservation in
                    recoveredCount += 1
                    admission.release(reservation)
                }
            )
            #expect(reservation == nil)
        }

        admission.setCloseTeardownDegraded(false)
        #expect(
            admission.debugOwnerCount == 1,
            "admission reserved every available recovery slot before the main actor ran"
        )
        for _ in 0..<100 where recoveredCount < 3 {
            await Task.yield()
        }
        #expect(recoveredCount == 3)
        #expect(admission.debugOwnerCount == 0)
    }

    @Test func stuckHibernationFreeDoesNotStrandAnotherAdmissionOrClose() async throws {
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
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        let isolatedTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.isolatedHibernation",
                surface: isolatedSurface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: isolatedReservation,
                freeSurface: { _ in
                    isolatedFreeStarted.continuation.yield()
                    _ = releaseIsolatedFree.wait(timeout: .distantFuture)
                }
            )
        )
        var isolatedFreeIterator = isolatedFreeStarted.stream.makeAsyncIterator()
        _ = await isolatedFreeIterator.next()

        let secondReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        #expect(await coordinator.reserveIsolatedHibernationTeardown() == nil)
        let secondIsolatedTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.secondIsolatedHibernation",
                surface: queuedIsolatedSurface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: secondReservation,
                freeSurface: { _ in
                    secondIsolatedFreeCount.withLock { $0 += 1 }
                }
            )
        )
        let closeTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.boundedClose",
                surface: closeSurface,
                callbackContext: nil,
                freeSurface: { _ in
                    closeFreeCount.withLock { $0 += 1 }
                }
            )
        )

        #expect(await closeTicket.wait(timeout: .seconds(1)))
        #expect(await secondIsolatedTicket.wait(timeout: .seconds(1)))
        #expect(closeFreeCount.withLock { $0 } == 1)
        #expect(await isolatedTicket.wait(timeout: .zero) == false)
        #expect(secondIsolatedFreeCount.withLock { $0 } == 1)

        let replacementReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        #expect(await coordinator.reserveIsolatedHibernationTeardown() == nil)
        await coordinator.cancelIsolatedHibernationTeardown(replacementReservation)
        releaseIsolatedFree.signal()
        #expect(await isolatedTicket.wait(timeout: .seconds(1)))
        let nextReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        await coordinator.cancelIsolatedHibernationTeardown(nextReservation)
    }

    @Test func staleIsolatedReservationFallsBackToBoundedClose() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let freeCount = OSAllocatedUnfairLock(initialState: 0)
        let staleReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        await coordinator.cancelIsolatedHibernationTeardown(staleReservation)

        let ticket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.staleIsolatedReservation",
                surface: surface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: staleReservation,
                freeSurface: { _ in
                    freeCount.withLock { $0 += 1 }
                }
            )
        )

        #expect(await ticket.wait(timeout: .seconds(1)))
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
