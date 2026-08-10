import Dispatch
import Foundation
import os
import Testing
@testable import CmuxTerminal

/// Records freed pointers and publishes one event for each completed free.
private final class FreedSurfaceRecorder: @unchecked Sendable {
    /// Freed pointers as Sendable bit patterns.
    private let state = OSAllocatedUnfairLock(initialState: [UInt]())
    private let events: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: Int.self)
    }

    func record(_ pointerBits: UInt) {
        let count = state.withLock { freed in
            freed.append(pointerBits)
            return freed.count
        }
        continuation.yield(count)
    }

    /// Suspends until `count` frees have been recorded.
    func waitForFreeCount(_ count: Int) async {
        guard state.withLock({ $0.count }) < count else { return }
        for await recordedCount in events where recordedCount >= count {
            return
        }
    }

    var freed: [UInt] {
        state.withLock { $0 }
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
                    recorder.record(UInt(bitPattern: pointer))
                }
            )
        )

        await recorder.waitForFreeCount(1)
        #expect(await ticket.wait(timeout: .seconds(1)))
        #expect(recorder.freed == [UInt(bitPattern: surface)])
    }

    @MainActor
    @Test func nativeFreeWorkersUseDedicatedThreadsAndStayBoundedByAdmittedSlots() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<5).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let runtimeReservations = try (0..<surfaces.count).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let isolatedReservations = [
            try #require(await coordinator.reserveIsolatedHibernationTeardown()),
            try #require(await coordinator.reserveIsolatedHibernationTeardown()),
        ]
        let workerStarted = AsyncStream<Int>.makeStream()
        let releaseWorkers = (0..<surfaces.count).map { _ in
            DispatchSemaphore(value: 0)
        }
        let workerState = OSAllocatedUnfairLock(
            initialState: (
                active: 0,
                maximumActive: 0,
                observedCurrentTask: false,
                startsByIndex: [Int: Int]()
            )
        )
        defer {
            for releaseWorker in releaseWorkers {
                releaseWorker.signal()
            }
            workerStarted.continuation.finish()
        }

        var tickets: [TerminalSurfaceRuntimeTeardownTicket] = []
        for index in 0..<4 {
            let executionLane: TerminalSurfaceRuntimeTeardownExecutionLane =
                index < 2 ? .boundedClose : .isolatedHibernation
            let isolatedReservation =
                index < 2 ? nil : isolatedReservations[index - 2]
            tickets.append(
                try requireTeardownTicket(
                    coordinator.enqueueRuntimeTeardown(
                        id: UUID(),
                        workspaceId: UUID(),
                        reason: "test.dedicatedWorker.\(index)",
                        surface: surfaces[index],
                        callbackContext: nil,
                        manualIOContext: nil,
                        byteTeeLease: nil,
                        runtimeOwnershipReservation: runtimeReservations[index],
                        executionLane: executionLane,
                        isolatedHibernationReservation: isolatedReservation,
                        freeSurface: { _ in
                            let hasCurrentTask = withUnsafeCurrentTask { $0 != nil }
                            workerState.withLock { state in
                                state.active += 1
                                state.maximumActive = max(
                                    state.maximumActive,
                                    state.active
                                )
                                state.observedCurrentTask =
                                    state.observedCurrentTask || hasCurrentTask
                                state.startsByIndex[index, default: 0] += 1
                            }
                            workerStarted.continuation.yield(index)
                            releaseWorkers[index].wait()
                            workerState.withLock { $0.active -= 1 }
                        }
                    )
                )
            )
        }

        var workerStartedIterator = workerStarted.stream.makeAsyncIterator()
        var firstStartedIndices = Set<Int>()
        while firstStartedIndices.count < 4 {
            firstStartedIndices.insert(
                try #require(await workerStartedIterator.next())
            )
        }
        #expect(firstStartedIndices == Set(0..<4))
        #expect(await coordinator.reserveIsolatedHibernationTeardown() == nil)

        let fifthTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.dedicatedWorker.4",
                surface: surfaces[4],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: runtimeReservations[4],
                freeSurface: { _ in
                    let hasCurrentTask = withUnsafeCurrentTask { $0 != nil }
                    workerState.withLock { state in
                        state.active += 1
                        state.maximumActive = max(
                            state.maximumActive,
                            state.active
                        )
                        state.observedCurrentTask =
                            state.observedCurrentTask || hasCurrentTask
                        state.startsByIndex[4, default: 0] += 1
                    }
                    workerStarted.continuation.yield(4)
                    releaseWorkers[4].wait()
                    workerState.withLock { $0.active -= 1 }
                }
            )
        )
        tickets.append(fifthTicket)

        releaseWorkers[0].signal()
        let fifthStartedIndex = try #require(
            await workerStartedIterator.next()
        )
        #expect(fifthStartedIndex == 4)
        for index in 1..<releaseWorkers.count {
            releaseWorkers[index].signal()
        }
        for ticket in tickets {
            #expect(await ticket.wait(timeout: nil))
        }

        let finalWorkerState = workerState.withLock { $0 }
        #expect(finalWorkerState.active == 0)
        #expect(finalWorkerState.maximumActive == 4)
        #expect(finalWorkerState.observedCurrentTask == false)
        #expect(
            finalWorkerState.startsByIndex
                == Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, 1) })
        )
    }

    @Test func teardownsForMultipleSurfacesAllFree() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FreedSurfaceRecorder()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let reservations = try (0..<surfaces.count).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }

        for (surface, reservation) in zip(surfaces, reservations) {
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.batch",
                surface: surface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: reservation,
                freeSurface: { pointer in
                    recorder.record(UInt(bitPattern: pointer))
                }
            )
        }

        await recorder.waitForFreeCount(surfaces.count)
        #expect(Set(recorder.freed) == Set(surfaces.map { UInt(bitPattern: $0) }))
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

        let secondReservation = try #require(
            coordinator.reserveRuntimeSurfaceOwnership()
        )
        let thirdReservation = try #require(
            coordinator.reserveRuntimeSurfaceOwnership()
        )

        let secondTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.closeAfterStuckClose",
                surface: surfaces[1],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: secondReservation,
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
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: thirdReservation,
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

    @MainActor
    @Test func boundedIngressDropsNewestSubmissionWithoutLeakingOwnershipOrWaiter() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let surfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let isolatedReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        let admittedTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.fillBoundedIngress",
                surface: surfaces[0],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: isolatedReservation,
                freeSurface: { _ in }
            )
        )

        // While this test owns MainActor, the consumer either has the admitted
        // request buffered or waits for MainActor to validate its reservation.
        // Two owner-free messages therefore fill the two-element buffer in
        // either schedule.
        coordinator.cancelAllRuntimeTeardowns()
        coordinator.cancelAllRuntimeTeardowns()

        let droppedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.dropNewestIngressSubmission",
            surface: surfaces[1],
            callbackContext: nil,
            freeSurface: { _ in }
        )
        #expect(droppedTicket == nil)
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 1)

        #expect(
            await coordinator.cancelRuntimeTeardown(ticketID: UUID()) == false
        )
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 1)

        #expect(await admittedTicket.wait(timeout: nil))
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)
    }

    @Test func cancellationBeforeStartStillFreesOwnedSurface() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<3).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let reservations = try (0..<3).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let activeFreesStarted = AsyncStream<Void>.makeStream()
        let cancelledFreeStarted = AsyncStream<Void>.makeStream()
        let releaseActiveFrees = DispatchSemaphore(value: 0)
        defer {
            releaseActiveFrees.signal()
            releaseActiveFrees.signal()
            activeFreesStarted.continuation.finish()
            cancelledFreeStarted.continuation.finish()
        }

        let activeTickets = try (0..<2).map { index in
            try requireTeardownTicket(
                coordinator.enqueueRuntimeTeardown(
                    id: UUID(),
                    workspaceId: UUID(),
                    reason: "test.activeBeforeCancellation",
                    surface: surfaces[index],
                    callbackContext: nil,
                    manualIOContext: nil,
                    byteTeeLease: nil,
                    runtimeOwnershipReservation: reservations[index],
                    freeSurface: { _ in
                        activeFreesStarted.continuation.yield()
                        releaseActiveFrees.wait()
                    }
                )
            )
        }
        var activeFreesIterator = activeFreesStarted.stream.makeAsyncIterator()
        _ = await activeFreesIterator.next()
        _ = await activeFreesIterator.next()

        let cancelledTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.cancelledBeforeStart",
                surface: surfaces[2],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: reservations[2],
                freeSurface: { _ in
                    cancelledFreeStarted.continuation.yield()
                }
            )
        )
        #expect(
            await coordinator.cancelRuntimeTeardown(
                ticketID: cancelledTicket.id
            )
        )

        releaseActiveFrees.signal()
        var cancelledFreeIterator =
            cancelledFreeStarted.stream.makeAsyncIterator()
        _ = await cancelledFreeIterator.next()
        #expect(await cancelledTicket.wait(timeout: nil))

        releaseActiveFrees.signal()
        for ticket in activeTickets {
            #expect(await ticket.wait(timeout: nil))
        }
    }

    @Test func cancellationDuringRunUsesNormalCompletionSignal() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let freeStarted = AsyncStream<Void>.makeStream()
        let releaseFree = DispatchSemaphore(value: 0)
        defer {
            releaseFree.signal()
            freeStarted.continuation.finish()
        }

        let ticket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.cancelledDuringRun",
                surface: surface,
                callbackContext: nil,
                freeSurface: { _ in
                    freeStarted.continuation.yield()
                    releaseFree.wait()
                }
            )
        )
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()

        #expect(
            await coordinator.cancelRuntimeTeardown(ticketID: ticket.id)
        )
        releaseFree.signal()

        #expect(await ticket.wait(timeout: nil))
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)
    }

    @Test func completionReleasesResourcesAndSlotExactlyOnce() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let recorder = TeardownLifetimeRecorder()
        let lease = LifetimeRecordingByteTeeLease(recorder: recorder)

        let ticket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.exactlyOnce",
                surface: surfaces[0],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: lease,
                freeSurface: { _ in recorder.record("free") }
            )
        )
        #expect(await ticket.wait(timeout: nil))
        #expect(
            await coordinator.cancelRuntimeTeardown(ticketID: ticket.id)
                == false
        )
        #expect(recorder.snapshot() == ["free", "tee.release"])
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)

        let nextTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.slotReused",
                surface: surfaces[1],
                callbackContext: nil,
                freeSurface: { _ in }
            )
        )
        #expect(await nextTicket.wait(timeout: nil))
        #expect(await !coordinator.debugCloseTeardownDegraded)
    }

    @Test func twoStuckClosesBoundAdmissionUntilAWorkerRecovers() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
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

        let recovery = AsyncStream<
            TerminalSurfaceRuntimeOwnershipReservation
        >.makeStream(bufferingPolicy: .bufferingNewest(1))
        let recoveryID = UUID()
        #expect(
            coordinator.reserveRuntimeSurfaceOwnership(
                recoveryID: recoveryID,
                onRecovery: { reservation in
                    recovery.continuation.yield(reservation)
                    recovery.continuation.finish()
                }
            ) == .deferred
        )

        releaseFrees.signal()
        var recoveryIterator = recovery.stream.makeAsyncIterator()
        let recoveredReservation = try #require(
            await recoveryIterator.next()
        )
        coordinator.cancelRuntimeSurfaceOwnership(recoveredReservation)
        releaseFrees.signal()
        #expect(await firstTicket.wait(timeout: .seconds(1)))
        #expect(await secondTicket.wait(timeout: .seconds(1)))
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)
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
        let nextRecovery = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let staleResult = admission.reserve(
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
        let nextResult = admission.reserve(
            recoveryID: nextRecoveryID,
            onRecovery: { reservation in
                nextRecoveryRan = true
                nextRecovery.continuation.yield()
                nextRecovery.continuation.finish()
                admission.release(reservation)
            }
        )
        #expect(staleResult == .deferred)
        #expect(nextResult == .deferred)

        admission.release(firstOwner)
        staleProbe = nil
        #expect(releasedProbe == nil)
        var nextRecoveryIterator = nextRecovery.stream.makeAsyncIterator()
        _ = await nextRecoveryIterator.next()

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
        let recoveries = AsyncStream<Void>.makeStream()

        for _ in 0..<3 {
            let result = admission.reserve(
                recoveryID: UUID(),
                onRecovery: { reservation in
                    recoveredCount += 1
                    recoveries.continuation.yield()
                    admission.release(reservation)
                }
            )
            #expect(result == .deferred)
        }

        admission.setCloseTeardownDegraded(false)
        #expect(
            admission.debugOwnerCount == 1,
            "admission reserved every available recovery slot before the main actor ran"
        )
        var recoveryIterator = recoveries.stream.makeAsyncIterator()
        for _ in 0..<3 {
            _ = await recoveryIterator.next()
        }
        recoveries.continuation.finish()
        #expect(recoveredCount == 3)
        #expect(admission.debugOwnerCount == 0)
    }

    @MainActor
    @Test func recoveryAdmissionReservesImmediatelyWhenCapacityIsAvailable() {
        let admission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: 2
        )
        var recoveryRan = false

        let result = admission.reserve(
            recoveryID: UUID(),
            onRecovery: { _ in recoveryRan = true }
        )
        let reservation: TerminalSurfaceRuntimeOwnershipReservation
        switch result {
        case .reserved(let admittedReservation):
            reservation = admittedReservation
        case .deferred, .rejected:
            Issue.record("available ownership did not reserve immediately")
            return
        }

        #expect(admission.contains(reservation))
        #expect(admission.debugOwnerCount == 1)
        #expect(!recoveryRan)
        admission.release(reservation)
        #expect(admission.debugOwnerCount == 0)
    }

    @MainActor
    @Test func queuedRecoveryRetryReservesImmediatelyWhenCapacityIsAvailable() async throws {
        let admission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: 2
        )
        let firstOwner = try #require(admission.reserve())
        let secondOwner = try #require(admission.reserve())
        let leadingRecovery = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let recoveryID = UUID()
        var queuedRecoveryRan = false
        var retryRecoveryRan = false

        #expect(
            admission.reserve(
                recoveryID: UUID(),
                onRecovery: { reservation in
                    admission.release(reservation)
                    leadingRecovery.continuation.yield()
                    leadingRecovery.continuation.finish()
                }
            ) == .deferred
        )
        #expect(
            admission.reserve(
                recoveryID: recoveryID,
                onRecovery: { reservation in
                    queuedRecoveryRan = true
                    admission.release(reservation)
                }
            ) == .deferred
        )

        admission.release(firstOwner)
        admission.release(secondOwner)
        let retryResult = admission.reserve(
            recoveryID: recoveryID,
            onRecovery: { _ in retryRecoveryRan = true }
        )
        let retryReservation: TerminalSurfaceRuntimeOwnershipReservation
        switch retryResult {
        case .reserved(let reservation):
            retryReservation = reservation
        case .deferred, .rejected:
            Issue.record("available same-ID retry did not reserve immediately")
            return
        }

        #expect(admission.contains(retryReservation))
        #expect(!queuedRecoveryRan)
        #expect(!retryRecoveryRan)
        admission.release(retryReservation)
        var leadingRecoveryIterator = leadingRecovery.stream.makeAsyncIterator()
        _ = await leadingRecoveryIterator.next()
        #expect(admission.debugOwnerCount == 0)
    }

    @MainActor
    @Test func recoveryQueueRejectsNewIDsAtOwnershipCapacity() async throws {
        let admission = TerminalSurfaceRuntimeOwnershipAdmission(
            maximumOwnerCount: 2
        )
        let firstOwner = try #require(admission.reserve())
        let secondOwner = try #require(admission.reserve())
        let recoveries = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let firstRecoveryID = UUID()
        let secondRecoveryID = UUID()
        var replacedRecoveryRan = false
        var thirdRecoveryRan = false

        let firstResult = admission.reserve(
            recoveryID: firstRecoveryID,
            onRecovery: { _ in replacedRecoveryRan = true }
        )
        #expect(firstResult == .deferred)
        let replacementResult = admission.reserve(
            recoveryID: firstRecoveryID,
            onRecovery: { reservation in
                admission.release(reservation)
                recoveries.continuation.yield(0)
            }
        )
        #expect(replacementResult == .deferred)
        let secondResult = admission.reserve(
            recoveryID: secondRecoveryID,
            onRecovery: { reservation in
                admission.release(reservation)
                recoveries.continuation.yield(1)
                recoveries.continuation.finish()
            }
        )
        #expect(secondResult == .deferred)
        let thirdResult = admission.reserve(
            recoveryID: UUID(),
            onRecovery: { reservation in
                thirdRecoveryRan = true
                admission.release(reservation)
            }
        )
        #expect(thirdResult == .rejected)

        admission.release(firstOwner)
        var recoveryIterator = recoveries.stream.makeAsyncIterator()
        #expect(await recoveryIterator.next() == 0)
        #expect(await recoveryIterator.next() == 1)
        #expect(
            admission.debugOwnerCount == 1,
            "a third recovery reservation exceeded the bounded owner count"
        )
        #expect(
            !replacedRecoveryRan,
            "same-ID recovery replacement retained the prior action"
        )
        #expect(
            !thirdRecoveryRan,
            "a recovery request beyond the owner capacity was retained"
        )
        admission.release(secondOwner)
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
        let surfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for surface in surfaces { surface.deallocate() } }
        let isolatedFreeStarted = AsyncStream<Void>.makeStream()
        let releaseIsolatedFree = DispatchSemaphore(value: 0)
        let freeCount = OSAllocatedUnfairLock(initialState: 0)
        defer {
            releaseIsolatedFree.signal()
            isolatedFreeStarted.continuation.finish()
        }
        let staleReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        await coordinator.cancelIsolatedHibernationTeardown(staleReservation)
        let blockingReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        let blockingTicket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.blockingIsolatedReservation",
                surface: surfaces[0],
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                executionLane: .isolatedHibernation,
                isolatedHibernationReservation: blockingReservation,
                freeSurface: { _ in
                    isolatedFreeStarted.continuation.yield()
                    _ = releaseIsolatedFree.wait(timeout: .distantFuture)
                }
            )
        )
        var isolatedFreeIterator = isolatedFreeStarted.stream.makeAsyncIterator()
        _ = await isolatedFreeIterator.next()

        let ticket = try requireTeardownTicket(
            coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.staleIsolatedReservation",
                surface: surfaces[1],
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
        #expect(await blockingTicket.wait(timeout: .zero) == false)

        releaseIsolatedFree.signal()
        #expect(await blockingTicket.wait(timeout: .seconds(1)))
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
