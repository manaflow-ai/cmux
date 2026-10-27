@testable import CmuxNextSettings
import Foundation
import os
import Testing

/// `ConfigFileWatcher.startWithoutWaiting`: the watch is armed on the watcher's queue, not the
/// caller's thread; the initial change comes after the watch exists, so a save made right after the
/// start is seen; a `stop()` called right after it still ends the watch (p08-startup 025).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConfigFileWatcherStartTests {
    /// A watched file's changes, counted and streamed.
    final class Changes: Sendable {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func record() {
            count.withLock { $0 += 1 }
            continuation.yield()
        }
    }

    static func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watcher-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        return url
    }

    @Test func aSaveRightAfterTheStartIsSeen() async throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let changes = Changes()
        let watcher = ConfigFileWatcher(url: url) { changes.record() }
        defer { watcher.stop() }
        watcher.startWithoutWaiting()
        var events = changes.stream.makeAsyncIterator()
        _ = await events.next()  // the initial change: the watch exists now
        try Data(#"{ "appearance": { "density": "compact" } }"#.utf8).write(to: url, options: .atomic)
        _ = await events.next()
        #expect(changes.count.withLock { $0 } >= 2, "a save made right after the start was lost")
    }

    @Test func aStopRightAfterTheStartEndsTheWatch() async throws {
        let url = try Self.file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let changes = Changes()
        let watcher = ConfigFileWatcher(url: url) { changes.record() }
        watcher.startWithoutWaiting(reportInitialChange: false)
        watcher.stop()  // the queue runs the arm, then this: no source is left after it returns
        // A second watcher's change is the barrier: the kernel delivered the save's events.
        let barrier = Changes()
        let witness = ConfigFileWatcher(url: url) { barrier.record() }
        defer { witness.stop() }
        witness.start(reportInitialChange: false)
        try Data(#"{ "appearance": { "density": "cozy" } }"#.utf8).write(to: url, options: .atomic)
        var seen = barrier.stream.makeAsyncIterator()
        _ = await seen.next()
        #expect(changes.count.withLock { $0 } == 0, "a stop right after startWithoutWaiting left the watch armed")
    }
}
