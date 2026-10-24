import Foundation
import Testing
@testable import CmuxHomeCore

/// A flush waits for the write that is already running. The coalesced write takes the state
/// (clearing `dirty`) and then awaits the cache actor; a flush during that await (the app's quit)
/// found nothing dirty and returned at once, so the process could exit while the actor still
/// encoded or wrote the file, and a draft typed just before Quit was lost.
@MainActor
@Suite struct HomeCacheFlushInFlightTests {
    static let austin = ConversationID("conv_austin")

    /// A writer whose writes end only when the test releases them.
    actor GatedWriter: HomeCacheWriting {
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private var gates: [CheckedContinuation<Void, Never>] = []
        private(set) var finished = 0

        init() { (started, startedContinuation) = AsyncStream.makeStream() }

        func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) async -> Bool {
            startedContinuation.yield()
            await withCheckedContinuation { gates.append($0) }
            finished += 1
            return true
        }

        func release() {
            let waiting = gates
            gates = []
            waiting.forEach { $0.resume() }
        }
    }

    @Test func aFlushDuringARunningWriteWaitsForIt() async {
        let writer = GatedWriter()
        let view = HomeClientViewCache(cache: writer, writeDelay: .zero, clock: ContinuousClock())
        view.ownerState = { HomeCacheState() }
        view.setDraft("typed just before Quit", for: Self.austin)
        var started = writer.started.makeAsyncIterator()
        await started.next()

        // The flush starts while that write still runs; the test resumes once the flush waits (or returned).
        let (flushStarted, flushStartedContinuation) = AsyncStream<Void>.makeStream()
        let flush = Task { @MainActor in
            flushStartedContinuation.yield()
            await view.flush()
            return await writer.finished
        }
        var flushing = flushStarted.makeAsyncIterator()
        await flushing.next()
        await writer.release()
        #expect(await flush.value == 1, "the flush returned while the coalesced write was still running")
    }
}
