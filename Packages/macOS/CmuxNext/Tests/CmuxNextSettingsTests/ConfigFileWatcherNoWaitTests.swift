@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// `ConfigFileWatcher.start` and `stop` never wait for the watcher's queue (p02-threads-035): the main
/// thread starts and stops watchers, and its `queue.sync` waited for whatever the queue was running (a
/// consumer's `onChange`, a directory walk on a slow volume). A save made after a quiet start, before its
/// arm runs, is still reported; no change is reported after `stop` returns.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConfigFileWatcherNoWaitTests {
    /// An `onChange` whose first call holds the watcher's queue until ``open()``.
    final class Hold: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let entered: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let release = DispatchSemaphore(value: 0)

        init() { (entered, continuation) = AsyncStream.makeStream(of: Void.self) }

        func onChange() {
            let call = calls.withLock { calls in
                calls += 1
                return calls
            }
            continuation.yield()
            if call == 1 { release.wait() }  // the test's own hold of the watcher's queue
        }

        func open() { release.signal() }
    }

    @Test func startAndStopReturnWhileTheQueueIsBusyAndASaveBeforeTheArmIsSeen() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hold = Hold()
        let watcher = ConfigFileWatcher(url: url) { hold.onChange() }
        var entered = hold.entered.makeAsyncIterator()
        watcher.start()
        _ = await entered.next()  // the initial change now holds the watcher's queue
        // Before p02-threads-035 both calls waited for the queue here, so the test hit its time limit.
        watcher.stop()
        watcher.start(reportInitialChange: false)
        try Data(#"{ "appearance": { "density": "compact" } }"#.utf8).write(to: url, options: .atomic)
        hold.open()
        _ = await entered.next()
        #expect(hold.calls.withLock { $0 } >= 2, "a save made before the quiet start's arm was lost")
        watcher.stop()
    }

    @Test func noChangeIsReportedAfterStopReturns() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hold = Hold()
        let watcher = ConfigFileWatcher(url: url) { hold.onChange() }
        var entered = hold.entered.makeAsyncIterator()
        watcher.start()
        _ = await entered.next()  // the queue is held: the save's events wait behind it
        try Data(#"{ "appearance": { "density": "cozy" } }"#.utf8).write(to: url, options: .atomic)
        watcher.stop()
        hold.open()
        // A second watcher's change is the barrier: the kernel delivered the saves' events by then.
        let barrier = ConfigFileWatcherStartTests.Changes()
        let witness = ConfigFileWatcher(url: url) { barrier.record() }
        defer { witness.stop() }
        witness.start(reportInitialChange: false)
        try Data(#"{ "appearance": { "density": "compact" } }"#.utf8).write(to: url, options: .atomic)
        var seen = barrier.stream.makeAsyncIterator()
        _ = await seen.next()
        #expect(hold.calls.withLock { $0 } == 1, "the stopped watcher reported a change after stop returned")
    }
}
