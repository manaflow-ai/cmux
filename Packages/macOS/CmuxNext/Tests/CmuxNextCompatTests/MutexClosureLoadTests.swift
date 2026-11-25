import CmuxNextCompat
import Foundation
import Testing

/// A closure kept in a ``Mutex`` and read with `load()` stays one call deep however often it is
/// read (#40144: `withLock { $0 }` wrapped it in two more thunks per read).
@Suite nonisolated struct MutexClosureLoadTests {
    @Test func loadingAClosureManyTimesDoesNotDeepenItsCall() throws {
        let depths = Depths()
        let handler = Mutex<(@Sendable () -> Void)?>(nil)
        handler.store({ depths.note() })
        try #require(handler.load() != nil)
        handler.load()?()
        for _ in 0..<1_000 { _ = handler.load() }
        handler.load()?()
        let seen = depths.values.load()
        #expect(seen.count == 2)
        #expect(seen.last == seen.first, "stack depth grew from \(seen.first ?? 0) to \(seen.last ?? 0) frames")
    }

    @Test func storeReplacesTheValue() {
        let value = Mutex(1)
        value.store(2)
        #expect(value.load() == 2)
        #expect(value.withLock { $0 } == 2)
    }
}

/// The call-stack depth at each call (a class: a ``Mutex`` cannot be captured).
private nonisolated final class Depths: Sendable {
    let values = Mutex<[Int]>([])
    @inline(never)
    nonisolated func note() {
        let depth = Thread.callStackReturnAddresses.count
        values.withLock { $0.append(depth) }
    }
}
