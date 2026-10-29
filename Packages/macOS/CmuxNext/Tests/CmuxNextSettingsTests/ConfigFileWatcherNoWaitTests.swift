#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// `ConfigFileWatcher.start` and `stop` never wait for the watcher's queue: the main
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

    /// A watch armed long after its consumer read the file (the Ghostty config watch, posted after
    /// startup) reports a save made between the read's ``mark()`` and the arm: a write
    /// in place, a rename over the file, a delete, a file that appears.
    @Test(arguments: SaveKind.allCases)
    func aSaveSinceTheMarkIsReportedWhenALaterWatchArms(_ save: SaveKind) async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if save == .create { try FileManager.default.removeItem(at: url) }
        let queue = DispatchQueue(label: "test.config-watcher.mark-save", qos: .utility)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.mark()
        await Self.fence(queue)  // the mark is recorded
        let saved = Data(#"{ "appearance": { "density": "compact" } }"#.utf8)
        switch save {
        case .inPlace: try saved.write(to: url)
        case .atomic: try saved.write(to: url, options: .atomic)
        case .delete: try FileManager.default.removeItem(at: url)
        case .create: try saved.write(to: url)
        }
        watcher.startFromMark()
        var seen = changes.stream.makeAsyncIterator()
        _ = await seen.next()  // a watch that only heard later edits sends no call and the test hits its time limit
        #expect(changes.count.withLock { $0 } >= 1)
    }

    enum SaveKind: CaseIterable, Sendable {
        case inPlace, atomic, delete, create
    }

    /// The folder's other entries are not the file: one added, renamed in or removed after the mark (cmux's
    /// own atomic writes in Application Support, another app's files in ~/.config) reports nothing at the arm.
    @Test func anotherEntryOfTheFolderSinceTheMarkReportsNothingWhenALaterWatchArms() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appending(path: "old-sibling.json"))
        let queue = DispatchQueue(label: "test.config-watcher.mark-sibling", qos: .utility)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.mark()
        await Self.fence(queue)
        try Data("{}".utf8).write(to: folder.appending(path: "sibling.json"))
        try Data("{}".utf8).write(to: folder.appending(path: "state.json"), options: .atomic)
        try FileManager.default.removeItem(at: folder.appending(path: "old-sibling.json"))
        watcher.startFromMark()
        await Self.fence(queue)  // the arm and its check ran
        #expect(changes.count.withLock { $0 } == 0, "a later arm reported another file of the folder as a save")
    }

    /// With no save since the mark, the later arm reports nothing.
    @Test func noSaveSinceTheMarkReportsNothingWhenALaterWatchArms() async throws {
        let url = try ConfigFileWatcherStartTests.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "test.config-watcher.mark-quiet", qos: .utility)
        let changes = ConfigFileWatcherStartTests.Changes()
        let watcher = ConfigFileWatcher(url: url, queue: queue) { changes.record() }
        defer { watcher.stop() }
        watcher.mark()
        watcher.startFromMark()
        await Self.fence(queue)
        #expect(changes.count.withLock { $0 } == 0, "a later arm reported a change no save made")
    }

    /// Runs after everything already queued on `queue`.
    private static func fence(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
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
