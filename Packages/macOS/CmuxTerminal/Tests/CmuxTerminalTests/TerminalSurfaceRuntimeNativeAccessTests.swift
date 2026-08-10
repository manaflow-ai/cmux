import Dispatch
import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import os
import Testing
@testable import CmuxTerminal

@Suite(.serialized) struct TerminalSurfaceRuntimeNativeAccessTests {
    @Test func finalBorrowStartsTheFirstTeardownExactlyOnce() throws {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let gate = TerminalSurfaceRuntimeNativeAccessGate()
        let firstBorrow = try #require(gate.acquireBorrow())
        let secondBorrow = try #require(gate.acquireBorrow())

        gate.requestTeardown {
            teardownBegun.withLock { $0 += 1 }
        }
        #expect(gate.acquireBorrow() == nil)
        #expect(teardownBegun.withLock { $0 } == 0)

        firstBorrow.release()
        #expect(teardownBegun.withLock { $0 } == 0)

        secondBorrow.release()
        secondBorrow.release()
        gate.requestTeardown {
            teardownBegun.withLock { $0 += 100 }
        }
        #expect(teardownBegun.withLock { $0 } == 1)
    }

    @Test func screenTailBorrowIsRejectedAfterTeardownStarts() async {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let releaseNativeFree = DispatchSemaphore(value: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let runtimeLifecycleId = UUID()
        let nativeAccessGate = TerminalSurfaceRuntimeNativeAccessGate()
        defer {
            releaseNativeFree.signal()
            surface.deallocate()
        }

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: runtimeLifecycleId,
            workspaceId: UUID(),
            reason: "test.teardownBeforeNativeBorrow",
            surface: surface,
            nativeAccessGate: nativeAccessGate,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            nativeTeardown: nativeTeardown(
                beginSurfaceTeardown: { _ in
                    teardownBegun.withLock { $0 += 1 }
                },
                freeSurface: { _ in
                    _ = releaseNativeFree.wait(timeout: .distantFuture)
                }
            )
        )
        let request = TerminalSurfaceRuntimeScreenTailRequest(
            surface: surface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: nativeAccessGate
        )

        #expect(request.nativeAccessGate.acquireBorrow() == nil)
        #expect(teardownBegun.withLock { $0 } == 1)

        releaseNativeFree.signal()
        #expect(await ticket.wait(timeout: .seconds(1)))
    }

    @Test func teardownWaitsForAnActiveScreenTailBorrow() async throws {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let nativeFreeCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let runtimeLifecycleId = UUID()
        let nativeAccessGate = TerminalSurfaceRuntimeNativeAccessGate()
        defer { surface.deallocate() }
        let surfaceBits = UInt(bitPattern: surface)
        cmux_test_ghostty_surface_read_blocking_begin(surface)
        defer {
            cmux_test_ghostty_surface_read_release()
            cmux_test_ghostty_surface_read_blocking_reset()
        }

        let borrowedSurface = UnsafeMutableRawPointer(bitPattern: surfaceBits)!
        let request = TerminalSurfaceRuntimeScreenTailRequest(
            surface: borrowedSurface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: nativeAccessGate
        )
        let readTask = Task {
            await coordinator.readScreenTailVT(request)
        }
        let readStarted = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            readStarted.continuation.yield(
                cmux_test_ghostty_surface_read_wait_until_started()
            )
            readStarted.continuation.finish()
        }
        var readStartedIterator = readStarted.stream.makeAsyncIterator()
        try #require(await readStartedIterator.next() == true)
        #expect(cmux_test_ghostty_surface_read_blocking_is_active())

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: runtimeLifecycleId,
            workspaceId: UUID(),
            reason: "test.activeNativeBorrow",
            surface: surface,
            nativeAccessGate: nativeAccessGate,
            callbackContext: nil,
            manualIOContext: nil,
            byteTeeLease: nil,
            nativeTeardown: nativeTeardown(
                beginSurfaceTeardown: { _ in
                    teardownBegun.withLock { $0 += 1 }
                },
                freeSurface: { _ in
                    nativeFreeCount.withLock { $0 += 1 }
                }
            )
        )

        #expect(
            teardownBegun.withLock { $0 } == 0,
            "process termination began while a native surface read held a borrow"
        )
        #expect(nativeFreeCount.withLock { $0 } == 0)
        #expect(await ticket.wait(timeout: .zero) == false)

        cmux_test_ghostty_surface_read_release()
        _ = await readTask.value

        #expect(await ticket.wait(timeout: .seconds(1)))
        #expect(teardownBegun.withLock { $0 } == 1)
        #expect(nativeFreeCount.withLock { $0 } == 1)
    }

    @Test func successfulScreenTailReadReturnsUTF8AndFreesNativeText() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        cmux_test_ghostty_surface_read_success_begin()
        defer {
            cmux_test_ghostty_surface_read_blocking_reset()
            surface.deallocate()
        }

        let request = TerminalSurfaceRuntimeScreenTailRequest(
            surface: surface,
            maxRows: 1,
            maxBytes: 64,
            nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate()
        )

        #expect(await coordinator.readScreenTailVT(request) == "screen tail ✓")
        #expect(cmux_test_ghostty_surface_free_text_call_count() == 1)
    }

    @Test func screenTailReadsDoNotOverlapNativeFormatting() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let firstSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let secondSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            cmux_test_ghostty_surface_read_release()
            cmux_test_ghostty_surface_read_blocking_reset()
            firstSurface.deallocate()
            secondSurface.deallocate()
        }
        cmux_test_ghostty_surface_read_blocking_begin(firstSurface)

        let firstRequest = TerminalSurfaceRuntimeScreenTailRequest(
            surface: firstSurface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate()
        )
        let secondRequest = TerminalSurfaceRuntimeScreenTailRequest(
            surface: secondSurface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate()
        )
        let firstRead = Task {
            await coordinator.readScreenTailVT(firstRequest)
        }
        let firstReadStarted = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            firstReadStarted.continuation.yield(
                cmux_test_ghostty_surface_read_wait_until_started()
            )
            firstReadStarted.continuation.finish()
        }
        var firstReadStartedIterator = firstReadStarted.stream.makeAsyncIterator()
        try #require(await firstReadStartedIterator.next() == true)

        let secondRead = Task(priority: .high) {
            await coordinator.readScreenTailVT(secondRequest)
        }
        let overlapProbe = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            let overlapped = cmux_test_ghostty_surface_read_wait_until_call_count(
                2,
                1_000
            )
            cmux_test_ghostty_surface_read_release()
            overlapProbe.continuation.yield(overlapped)
            overlapProbe.continuation.finish()
        }
        var overlapProbeIterator = overlapProbe.stream.makeAsyncIterator()
        let overlapResult = await overlapProbeIterator.next()
        guard let overlapped = overlapResult else {
            Issue.record("overlap probe ended without a result")
            return
        }

        _ = await firstRead.value
        _ = await secondRead.value

        #expect(overlapped == false)
        #expect(cmux_test_ghostty_surface_read_call_count() == 2)
        #expect(
            cmux_test_ghostty_surface_read_maximum_concurrent_call_count() == 1
        )
    }

    @Test func cancelledQueuedScreenTailReadDoesNotAcquireNativeAccess() async throws {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let firstSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let cancelledSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            cmux_test_ghostty_surface_read_release()
            cmux_test_ghostty_surface_read_blocking_reset()
            firstSurface.deallocate()
            cancelledSurface.deallocate()
        }
        cmux_test_ghostty_surface_read_blocking_begin(firstSurface)

        let firstRequest = TerminalSurfaceRuntimeScreenTailRequest(
            surface: firstSurface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate()
        )
        let cancelledGate = TerminalSurfaceRuntimeNativeAccessGate()
        let cancelledRequest = TerminalSurfaceRuntimeScreenTailRequest(
            surface: cancelledSurface,
            maxRows: 1,
            maxBytes: 1,
            nativeAccessGate: cancelledGate
        )
        let firstRead = Task {
            await coordinator.readScreenTailVT(firstRequest)
        }
        let firstReadStarted = AsyncStream<Bool>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
            firstReadStarted.continuation.yield(
                cmux_test_ghostty_surface_read_wait_until_started()
            )
            firstReadStarted.continuation.finish()
        }
        var firstReadStartedIterator = firstReadStarted.stream.makeAsyncIterator()
        try #require(await firstReadStartedIterator.next() == true)

        let cancelledRead = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await coordinator.readScreenTailVT(cancelledRequest)
        }
        cancelledGate.requestTeardown {
            teardownBegun.withLock { $0 += 1 }
        }
        #expect(
            teardownBegun.withLock { $0 } == 1,
            "a read queued behind another surface deferred process teardown"
        )
        cmux_test_ghostty_surface_read_release()

        _ = await firstRead.value
        _ = await cancelledRead.value

        #expect(cmux_test_ghostty_surface_read_call_count() == 1)
        #expect(teardownBegun.withLock { $0 } == 1)
    }

    /// Builds a paired fake native teardown without calling Ghostty.
    private func nativeTeardown(
        beginSurfaceTeardown: @escaping @Sendable (ghostty_surface_t) -> Void,
        freeSurface: @escaping @Sendable (ghostty_surface_t) -> Void
    ) -> TerminalSurfaceRuntimeNativeTeardown {
        TerminalSurfaceRuntimeNativeTeardown(
            beginSurfaceTeardown: beginSurfaceTeardown,
            freeSurface: freeSurface
        )
    }
}
