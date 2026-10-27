#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// `ConfigFileWatcher.start` and `stop` never wait for the watcher's queue (p02-threads-035): the main
/// thread starts and stops watchers, and its `queue.sync` waited for whatever the queue was running (a
/// consumer's `onChange`, a directory walk on a slow volume). A save made after a quiet start, before its
/// arm runs, is still reported; events after `stop` are not.
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

    @Test func startAndStopReturnWhileTheQueueIsBusy() async throws {
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
        #expect(hold.calls.withLock { $0 } >= 2, "the restarted watcher lost a save")
        watcher.stop()
    }

    /// A fresh watcher has no source until its arm runs, so only the arm's change-time check can see a
    /// save made between a quiet start and that arm.
    @Test func aSaveBetweenAQuietStartAndItsArmIsReported() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "test.config-watcher.held", qos: .utility)
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }  // the test's own hold of the watcher's queue: the arm waits behind it
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.start(reportInitialChange: false)
        try Data(#"{ "appearance": { "density": "compact" } }"#.utf8).write(to: url, options: .atomic)
        gate.signal()
        var seen = changes.stream.makeAsyncIterator()
        _ = await seen.next()  // without the change-time check no call comes and the test hits its time limit
        #expect(changes.count.withLock { $0 } >= 1)
    }

    /// The change-time check reports nothing when no save came after the quiet start.
    @Test func aQuietStartWithNoSaveReportsNothing() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "test.config-watcher.quiet", qos: .utility)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.start(reportInitialChange: false)
        await withCheckedContinuation { (armed: CheckedContinuation<Void, Never>) in queue.async { armed.resume() } }
        #expect(changes.count.withLock { $0 } == 0, "a quiet start reported a change no save made")
    }

    /// A watch armed after its consumer read the file (the Ghostty config watch, posted after startup,
    /// p08-startup-086) reports a save made between that read and the arm.
    @Test func aSaveSinceTheReadIsReportedWhenALaterWatchArms() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let since = ConfigFileWatcher.Since.now
        try Data(#"{ "appearance": { "density": "compact" } }"#.utf8).write(to: url, options: .atomic)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: DispatchQueue(label: "test.config-watcher.since", qos: .utility)) { changes.record() }
        defer { watcher.stop() }
        watcher.start(changedSince: since)
        var seen = changes.stream.makeAsyncIterator()
        _ = await seen.next()  // a watch that only heard later edits sends no call and the test hits its time limit
        #expect(changes.count.withLock { $0 } >= 1)
    }

    /// With no save since the read, the later arm reports nothing.
    @Test func noSaveSinceTheReadReportsNothingWhenALaterWatchArms() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let since = ConfigFileWatcher.Since.now
        let queue = DispatchQueue(label: "test.config-watcher.since-quiet", qos: .utility)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.start(changedSince: since)
        await withCheckedContinuation { (armed: CheckedContinuation<Void, Never>) in queue.async { armed.resume() } }
        #expect(changes.count.withLock { $0 } == 0, "a later arm reported a change no save made")
    }

    @Test func eventsQueuedBehindAStopAreNotReported() async throws {
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
        #expect(hold.calls.withLock { $0 } == 1, "the stopped watcher reported an event that came after stop")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// The main thread's start and stop make no blocking call (the task's acceptance: 0 detector records).
    @MainActor @Test func startAndStopOnTheMainThreadRecordNoBlockingCall() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let table = BlockingViolationTable(mode: .record)
        let watcher = ConfigFileWatcher(url: url) {}
        BlockingViolationTable.$scoped.withValue(table) {
            watcher.start()
            watcher.start(reportInitialChange: false)
            watcher.stop()
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty, "a watcher's start or stop blocked the main thread")
    }
    #endif
}
