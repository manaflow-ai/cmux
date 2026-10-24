import Foundation
import Testing
@testable import CmuxHomeCore

/// A forced exit (a second quit signal while a quit runs) calls the app's terminate path and then
/// `exit`. The Home cache's flush became awaited (it waits for the running write without a
/// semaphore), and the forced exit got no replacement: a draft typed within the 250 ms coalescing
/// window, or a state whose write was still on the cache actor, never reached disk. The forced
/// exit's last write now runs on its own thread, after the running write, before it returns.
@MainActor
@Suite struct HomeCacheForcedExitTests {
    static let austin = ConversationID("conv_austin")

    /// A pending coalesced change is on disk when the forced exit's write returns: no await, no
    /// clock advance (the coalescing delay never ends here).
    @Test func aPendingCoalescedDraftIsOnDiskWhenTheForcedExitWriteReturns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-forced-exit-\(UUID().uuidString)/home.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), clock: ManualClock(),
                              cache: HomeCache(url: url), cacheWriteDelay: .milliseconds(250))
        store.setDraft("typed just before the second Ctrl-C", for: Self.austin)
        #expect(store.viewCache.hasPendingWrite)

        #expect(store.flushCacheBeforeExit())

        // The next launch reads it.
        let snapshot = try #require(HomeCache(url: url).load(), "nothing on disk after the forced exit's write")
        #expect(snapshot.drafts == [Self.austin: "typed just before the second Ctrl-C"])
    }

    /// A writer whose async writes never end (a write still on the cache actor at the forced exit)
    /// and that records the states written on the forced exit's path.
    actor StuckWriter: HomeCacheWriting {
        // Test fake: written and read on the main actor only (the suite and the view cache).
        nonisolated(unsafe) var blocking: [HomeCacheState] = []
        let started: AsyncStream<Void>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let never: AsyncStream<Void>
        private let neverContinuation: AsyncStream<Void>.Continuation  // kept: `never` never finishes

        init() {
            (started, startedContinuation) = AsyncStream.makeStream()
            (never, neverContinuation) = AsyncStream.makeStream()
        }

        func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) async -> Bool {
            startedContinuation.yield()
            for await _ in never {}
            return false
        }

        nonisolated func writeBlocking(_ state: HomeCacheState, sequence: UInt64, writer: UUID) -> Bool {
            blocking.append(state)
            return true
        }
    }

    /// The running write took the state (nothing is dirty), so a write keyed on `dirty` alone
    /// would skip it: the forced exit writes the current state anyway, since the running write
    /// may never end before `exit`.
    @Test func aStateWhoseWriteStillRunsIsWrittenByTheForcedExit() async throws {
        let writer = StuckWriter()
        let view = HomeClientViewCache(cache: writer, writeDelay: .zero, clock: ContinuousClock())
        view.ownerState = { HomeCacheState() }
        view.setDraft("on the actor when the signal came", for: Self.austin)
        var started = writer.started.makeAsyncIterator()
        await started.next()

        #expect(view.flushBeforeExit())
        #expect(writer.blocking.map(\.drafts) == [[Self.austin: "on the actor when the signal came"]])
        // Nothing left: a second call writes nothing.
        view.flushBeforeExit()
        #expect(writer.blocking.count == 1)
    }
}
