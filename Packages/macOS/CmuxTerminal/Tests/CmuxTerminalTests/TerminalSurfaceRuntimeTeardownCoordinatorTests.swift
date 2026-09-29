import Dispatch
import Foundation
import os
import Testing
@testable import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

private final class TeardownFakeSurfaceController: TerminalSurfaceControlling {
    let surfaceId = UUID()
    let owningTabId = UUID()
    var runtimeSurfacePointer: ghostty_surface_t?
}

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
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
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
                runtimeSurfaceGeneration: 0,
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

    @Test func stuckCloseFreeDoesNotStrandLaterCloses() async throws {
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
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            freeSurface: { _ in
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
                runtimeSurfaceGeneration: 0,
                callbackContext: nil,
                freeSurface: { pointer in
                    let bits = UInt(bitPattern: pointer)
                    freedSurfaceBits.withLock {
                        _ = $0.insert(bits)
                    }
                }
            )
        }

        for ticket in laterTickets {
            try #require(
                await ticket.wait(timeout: .seconds(1)),
                "a stuck native free stranded a later close"
            )
        }
        #expect(await stuckTicket.wait(timeout: .zero) == false)
        #expect(
            freedSurfaceBits.withLock { $0 } ==
                Set(surfaces.dropFirst().map { UInt(bitPattern: $0) })
        )

        releaseStuckFree.signal()
        #expect(await stuckTicket.wait(timeout: .seconds(1)))
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
        let isolatedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.isolatedHibernation",
            surface: isolatedSurface,
            runtimeSurfaceGeneration: 0,
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
        var isolatedFreeIterator = isolatedFreeStarted.stream.makeAsyncIterator()
        _ = await isolatedFreeIterator.next()

        let secondReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        #expect(await coordinator.reserveIsolatedHibernationTeardown() == nil)
        let secondIsolatedTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.secondIsolatedHibernation",
            surface: queuedIsolatedSurface,
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            executionLane: .isolatedHibernation,
            isolatedHibernationReservation: secondReservation,
            freeSurface: { _ in
                secondIsolatedFreeCount.withLock { $0 += 1 }
            }
        )
        let closeTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.close",
            surface: closeSurface,
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            freeSurface: { _ in
                closeFreeCount.withLock { $0 += 1 }
            }
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
        let blockingTicket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.blockingIsolatedReservation",
            surface: surfaces[0],
            runtimeSurfaceGeneration: 0,
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
        var isolatedFreeIterator = isolatedFreeStarted.stream.makeAsyncIterator()
        _ = await isolatedFreeIterator.next()

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.staleIsolatedReservation",
            surface: surfaces[1],
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            executionLane: .isolatedHibernation,
            isolatedHibernationReservation: staleReservation,
            freeSurface: { _ in
                freeCount.withLock { $0 += 1 }
            }
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
            runtimeSurfaceGeneration: 0,
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

    // MARK: (B) ExternalHover native-surface lease

    @Test func acquireThenReleaseThenTeardownFreesImmediately() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)

        let lease = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )
        await coordinator.releaseExternalHoverLease(lease)

        let recorder = FreedSurfaceRecorder()
        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.leaseThenTeardown",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )
        #expect(await ticket.wait(timeout: .seconds(1)))
        await recorder.waitForFreeCount(1)
    }

    @Test func teardownWhileLeaseOutstandingDefersFreeUntilRelease() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)

        let lease = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )

        let recorder = FreedSurfaceRecorder()
        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.teardownWhileLeaseOutstanding",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )

        // The ticket must remain incomplete while the lease is still
        // outstanding.
        #expect(await ticket.wait(timeout: .milliseconds(50)) == false)
        #expect(await recorder.freed.isEmpty)

        // Releasing the last outstanding lease is what finally admits the
        // deferred free.
        await coordinator.releaseExternalHoverLease(lease)
        #expect(await ticket.wait(timeout: .seconds(1)))
        await recorder.waitForFreeCount(1)
    }

    @Test func acquireAfterTeardownRequestedFailsClosed() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.acquireAfterTeardown",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { _ in }
        )
        #expect(await ticket.wait(timeout: .seconds(1)))

        // A delayed acquire for the SAME lifetime, arriving after its
        // teardown has already been requested (and completed), must fail
        // closed — never hand out a lease for a pointer that may already
        // be freed.
        #expect(await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface) == nil)
    }

    @Test func hibernateOldGenerationFreeThenNewGenerationAcquireSucceeds() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surfaceID = UUID()
        nonisolated(unsafe) let oldSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        nonisolated(unsafe) let newSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            oldSurface.deallocate()
            newSurface.deallocate()
        }
        let oldLifetime = RuntimeSurfaceLifetimeID(surfaceID: surfaceID, runtimeSurfaceGeneration: 1)
        let newLifetime = RuntimeSurfaceLifetimeID(surfaceID: surfaceID, runtimeSurfaceGeneration: 2)

        // Hibernate: free the old generation via the coordinator.
        let ticket = coordinator.enqueueRuntimeTeardown(
            id: surfaceID,
            workspaceId: UUID(),
            reason: "test.hibernate",
            surface: oldSurface,
            runtimeSurfaceGeneration: oldLifetime.runtimeSurfaceGeneration,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            executionLane: .isolatedHibernation,
            isolatedHibernationReservation: nil,
            freeSurface: { _ in }
        )
        #expect(await ticket.wait(timeout: .seconds(1)))

        // Resume: a NEW generation on the SAME surfaceID must be acquirable —
        // the watermark only ever retires the specific generation it saw,
        // never the surfaceID as a whole (see RuntimeSurfaceLifetimeID).
        #expect(await coordinator.acquireExternalHoverLease(lifetimeID: newLifetime, surface: newSurface) != nil)

        // The OLD generation's lease request, arriving late, still fails closed.
        #expect(await coordinator.acquireExternalHoverLease(lifetimeID: oldLifetime, surface: oldSurface) == nil)
    }

    @Test func doubleReleaseOfTheSameLeaseIsANoOpAndNeverAdmitsAnUnrelatedDeferredFree() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)

        let leaseA = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )
        let leaseB = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )

        let recorder = FreedSurfaceRecorder()
        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.doubleRelease",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )

        // Releasing leaseA twice must not double-decrement and free while
        // leaseB (a genuinely different, still-outstanding lease) is live.
        await coordinator.releaseExternalHoverLease(leaseA)
        await coordinator.releaseExternalHoverLease(leaseA)
        #expect(await ticket.wait(timeout: .milliseconds(50)) == false)
        #expect(await recorder.freed.isEmpty)

        await coordinator.releaseExternalHoverLease(leaseB)
        #expect(await ticket.wait(timeout: .seconds(1)))
        await recorder.waitForFreeCount(1)
    }

    @Test func deferredIsolatedHibernationTeardownPreservesItsExecutionLaneAndReservation() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)

        let lease = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )
        let reservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        // The isolated lane's 2 slots are bounded; occupy the other one so
        // this assertion can observe whether the deferred admission still
        // requests an isolated slot (rather than silently falling back to
        // the default serialized-close lane, which would leak this
        // reservation's slot forever — review Blocking 3).
        let otherReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        #expect(await coordinator.reserveIsolatedHibernationTeardown() == nil)
        await coordinator.cancelIsolatedHibernationTeardown(otherReservation)

        let recorder = FreedSurfaceRecorder()
        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.deferredIsolatedHibernation",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            executionLane: .isolatedHibernation,
            isolatedHibernationReservation: reservation,
            freeSurface: { pointer in
                let bits = UInt(bitPattern: pointer)
                Task { await recorder.record(bits) }
            }
        )

        #expect(await ticket.wait(timeout: .milliseconds(50)) == false)

        await coordinator.releaseExternalHoverLease(lease)
        #expect(await ticket.wait(timeout: .seconds(1)))
        await recorder.waitForFreeCount(1)

        // The isolated slot the deferred admission used must have been
        // released — a fresh reservation request succeeds again.
        let afterReservation = try #require(
            await coordinator.reserveIsolatedHibernationTeardown()
        )
        await coordinator.cancelIsolatedHibernationTeardown(afterReservation)
    }

    // (C) ExternalHover diagnostics — drain liveness #6 (design-hover-
    // diagnostics-v4-final.md §8): "teardownとの競合でuse-after-free/
    // deadlockが起きない". Both sub-cases below assert the SAME ordering
    // invariant `admitTeardown` exists to guarantee: `drainDiagnostics`
    // always runs on a still-live surface, strictly before `freeSurface`
    // — never after, and never concurrently in a way that could race a
    // free.

    /// The straightforward admission path (no outstanding hover lease):
    /// `enqueue` calls `admitTeardown` directly, so the drain must still
    /// run before the free even with no deferral involved.
    @Test func immediateTeardownDrainsDiagnosticsBeforeFreeingTheSurface() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let recorder = TeardownLifetimeRecorder()

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.drainBeforeFree",
            surface: surface,
            runtimeSurfaceGeneration: 0,
            callbackContext: nil,
            freeSurface: { _ in recorder.record("free") },
            drainDiagnostics: { _, _ in recorder.record("drain") }
        )

        #expect(await ticket.wait(timeout: .seconds(1)))
        #expect(recorder.snapshot() == ["drain", "free"], "drainDiagnostics must run before freeSurface, never after")
    }

    /// The deferred-admission path: a teardown request arrives while a
    /// hover lease is still outstanding, is parked, and only admitted
    /// once the lease releases — `admitTeardown` runs then, from inside
    /// `releaseExternalHoverLease`. The drain must still land before the
    /// free on THIS path too (not just the no-lease-outstanding path
    /// above), and releasing the lease that was gating the free must not
    /// deadlock or use-after-free the surface the drain itself just
    /// touched.
    @Test func deferredTeardownAfterLeaseReleaseStillDrainsBeforeFreeing() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        nonisolated(unsafe) let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let lifetimeID = RuntimeSurfaceLifetimeID(surfaceID: UUID(), runtimeSurfaceGeneration: 1)
        let recorder = TeardownLifetimeRecorder()

        let lease = try #require(
            await coordinator.acquireExternalHoverLease(lifetimeID: lifetimeID, surface: surface)
        )

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.deferredDrainBeforeFree",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { _ in recorder.record("free") },
            drainDiagnostics: { _, _ in recorder.record("drain") }
        )

        // While the lease is outstanding, teardown must be fully parked
        // — neither the drain nor the free has run yet.
        #expect(await ticket.wait(timeout: .milliseconds(50)) == false)
        #expect(recorder.snapshot().isEmpty, "a deferred teardown must not drain or free while a hover lease is still outstanding")

        await coordinator.releaseExternalHoverLease(lease)
        #expect(await ticket.wait(timeout: .seconds(1)))
        #expect(recorder.snapshot() == ["drain", "free"], "the deferred admission must still drain before freeing")
    }

    @Test @MainActor
    func clipboardRequestIsInvalidatedBeforeNativeFree() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = TeardownLifetimeRecorder()
        let controller = TeardownFakeSurfaceController()
        let host = FakeTerminalSurfaceNativeView()
        let context = GhosttySurfaceCallbackContext(
            surfaceHost: host,
            surfaceController: controller,
            terminalLifecycleID: UUID()
        )
        let retainedContext = Unmanaged.passRetained(context)
        let surface = UnsafeMutableRawPointer.allocate(
            byteCount: 8,
            alignment: 8
        )
        defer { surface.deallocate() }
        #expect(context.bindRuntimeClipboardSurface(surface, generation: 7))

        let didRegisterClipboardRequest = context.registerRuntimeClipboardRequest(
            id: 29,
            onInvalidation: { _, completesNativeRequest, _, disposition in
                if case .discard = disposition {
                    // Expected before native free.
                } else {
                    Issue.record("Native teardown must discard deferred input")
                }
                recorder.record(
                    "clipboard.invalidate.\(completesNativeRequest)"
                )
            }
        )
        #expect(didRegisterClipboardRequest)
        #expect(context.commitRuntimeClipboardRequest(29))

        coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.clipboardLifetime",
            surface: surface,
            runtimeSurfaceGeneration: 0,
            callbackContext: retainedContext,
            freeSurface: { _ in
                recorder.record("surface.free")
            }
        )

        for await event in recorder.events where event == "surface.free" {
            break
        }
        #expect(
            recorder.snapshot() == [
                "clipboard.invalidate.true",
                "surface.free",
            ]
        )
    }
}
