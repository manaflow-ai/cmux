import Dispatch
import Foundation
import GhosttyRuntimeTestStubs
import os
import Testing
@testable import CmuxTerminal

@Suite(.serialized) struct TerminalSurfaceRuntimeNativeAccessTests {
    @Test func screenTailBorrowIsRejectedAfterTeardownStarts() async {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let releaseNativeFree = DispatchSemaphore(value: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            beginSurfaceTeardown: { _ in
                teardownBegun.withLock { $0 += 1 }
            }
        )
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            releaseNativeFree.signal()
            surface.deallocate()
        }

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.teardownBeforeNativeBorrow",
            surface: surface,
            callbackContext: nil,
            freeSurface: { _ in
                _ = releaseNativeFree.wait(timeout: .distantFuture)
            }
        )
        let request = TerminalSurfaceRuntimeScreenTailRequest(
            surface: surface,
            maxRows: 1,
            maxBytes: 1
        )

        #expect(coordinator.acquireScreenTailBorrow(for: request) == nil)
        #expect(teardownBegun.withLock { $0 } == 1)

        releaseNativeFree.signal()
        #expect(await ticket.wait(timeout: .seconds(1)))
    }

    @Test func teardownWaitsForAnActiveScreenTailBorrow() async throws {
        let teardownBegun = OSAllocatedUnfairLock(initialState: 0)
        let nativeFreeCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            beginSurfaceTeardown: { _ in
                teardownBegun.withLock { $0 += 1 }
            }
        )
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
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
            maxBytes: 1
        )
        let borrow = try #require(
            coordinator.acquireScreenTailBorrow(for: request)
        )
        let readTask = Task {
            await coordinator.readScreenTailVT(request, borrow: borrow)
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
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.activeNativeBorrow",
            surface: surface,
            callbackContext: nil,
            freeSurface: { _ in
                nativeFreeCount.withLock { $0 += 1 }
            }
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
}
