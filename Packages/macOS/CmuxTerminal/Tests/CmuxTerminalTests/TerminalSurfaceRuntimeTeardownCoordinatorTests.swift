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
