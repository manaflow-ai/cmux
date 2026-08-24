import Dispatch
import Foundation
import os
import Testing
@testable import CmuxTerminal
import GhosttyKit

/// Records native frees from an asynchronous teardown test.
private actor FenceFreedSurfaceRecorder {
    private(set) var freed: [UInt] = []
    private var continuations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ pointerBits: UInt) {
        freed.append(pointerBits)
        let count = freed.count
        for waiter in continuations.removeValue(forKey: count) ?? [] {
            waiter.resume()
        }
    }

    func waitForFreeCount(_ count: Int) async {
        guard freed.count < count else { return }
        await withCheckedContinuation { continuation in
            continuations[count, default: []].append(continuation)
        }
    }
}

@Suite
struct TerminalSurfaceRuntimeTeardownFenceTests {
    @Test
    func asyncBeforeFreeFenceOrdersNativeFree() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let recorder = FenceFreedSurfaceRecorder()
        let fenceStarted = AsyncStream<Void>.makeStream()
        let releaseFence = AsyncStream<Void>.makeStream()
        let freeStarted = OSAllocatedUnfairLock(initialState: false)
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer {
            surface.deallocate()
            fenceStarted.continuation.finish()
            releaseFence.continuation.finish()
        }

        let ticket = coordinator.enqueueRuntimeTeardown(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.asyncFence",
            surface: surface,
            callbackContext: nil,
            beforeFree: {
                fenceStarted.continuation.yield()
                var iterator = releaseFence.stream.makeAsyncIterator()
                _ = await iterator.next()
            },
            freeSurface: { pointer in
                freeStarted.withLock { $0 = true }
                Task {
                    await recorder.record(UInt(bitPattern: pointer))
                }
            }
        )

        var fenceIterator = fenceStarted.stream.makeAsyncIterator()
        _ = await fenceIterator.next()
        #expect(await ticket.wait(timeout: .zero) == false)
        #expect(freeStarted.withLock { $0 } == false)

        releaseFence.continuation.yield(())
        await recorder.waitForFreeCount(1)
        #expect(await ticket.wait(timeout: .seconds(1)))
        #expect(await recorder.freed == [UInt(bitPattern: surface)])
    }

    @Test
    func standaloneFenceTicketReleasesAfterFence() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let fenceStarted = AsyncStream<Void>.makeStream()
        let releaseFence = AsyncStream<Void>.makeStream()
        let cleanupFinished = AsyncStream<Void>.makeStream()
        defer {
            fenceStarted.continuation.finish()
            releaseFence.continuation.finish()
            cleanupFinished.continuation.finish()
        }

        let ticket = coordinator.enqueueRuntimeTeardownFence(
            id: UUID(),
            workspaceId: UUID(),
            reason: "test.standaloneFence",
            fence: {
                fenceStarted.continuation.yield()
                var iterator = releaseFence.stream.makeAsyncIterator()
                _ = await iterator.next()
            },
            onCompletion: {
                cleanupFinished.continuation.yield(())
            }
        )

        var fenceIterator = fenceStarted.stream.makeAsyncIterator()
        _ = await fenceIterator.next()
        #expect(await ticket.wait(timeout: .zero) == false)
        releaseFence.continuation.yield(())

        var cleanupIterator = cleanupFinished.stream.makeAsyncIterator()
        #expect(await cleanupIterator.next() != nil)
        #expect(await ticket.wait(timeout: .seconds(1)))
    }
}
