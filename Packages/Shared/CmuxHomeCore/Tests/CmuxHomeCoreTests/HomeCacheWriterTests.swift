import Foundation
import os
import Testing
@testable import CmuxHomeCore

/// The Home cache's file writes through its injected writer (S4 review, 2026-10-24): they run on the cache's
/// own queue, not a cooperative pool thread (a full pool must not hold the forced quit's last write), and a
/// quit's flush tries a failed write once more, then returns.
@MainActor
@Suite struct HomeCacheWriterTests {
    static let austin = ConversationID("conv_austin")

    /// Counts the writer's calls and fails the first `failures` of them.
    final class Writer: Sendable {
        // Lock carve-out: the writer is a synchronous callback on the cache's queue; the test reads it after.
        private let state = OSAllocatedUnfairLock<(calls: Int, labels: [String])>(initialState: (0, []))
        private let failures: Int

        init(failures: Int) { self.failures = failures }

        var calls: Int { state.withLock { $0.calls } }
        var labels: [String] { state.withLock { $0.labels } }

        func write(_ data: Data, _ url: URL) throws {
            let label = String(cString: __dispatch_queue_get_label(nil))
            let call = state.withLock { state -> Int in
                state.calls += 1
                state.labels.append(label)
                return state.calls
            }
            if call <= failures { throw CocoaError(.fileWriteUnknown) }
            try HomeCache.atomicWrite(data, to: url)
        }
    }

    static func cache(_ writer: Writer) -> HomeCache {
        HomeCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("home-writer-\(UUID().uuidString)/home.json"),
                  writeFile: { try writer.write($0, $1) })
    }

    @Test func writesRunOnTheCachesOwnQueue() async throws {
        let writer = Writer(failures: 0)
        let cache = Self.cache(writer)
        var snapshot = HomeCacheSnapshot()
        snapshot.drafts = [Self.austin: "on the queue"]
        try await cache.save(snapshot)
        #expect(!writer.labels.isEmpty)
        #expect(writer.labels.allSatisfy { $0 == "com.cmuxterm.home.cache" }, "\(writer.labels)")
    }

    @Test func aFailedWriteIsTriedOnceMoreByTheFlush() async throws {
        let writer = Writer(failures: 1)
        let cache = Self.cache(writer)
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        view.setDraft("typed during the quit", for: Self.austin)
        await view.flush()
        #expect(writer.calls == 2)
        #expect(try #require(cache.load()).drafts == [Self.austin: "typed during the quit"])
    }

    @Test func aWriteThatKeepsFailingEndsTheFlushAfterOneRetry() async {
        let writer = Writer(failures: .max)
        let cache = Self.cache(writer)
        let view = HomeClientViewCache(cache: cache, writeDelay: .zero, clock: ContinuousClock())
        view.setDraft("never on disk", for: Self.austin)
        await view.flush()
        #expect(writer.calls == 2, "the first write and one retry")
        #expect(cache.load() == nil)
    }
}
