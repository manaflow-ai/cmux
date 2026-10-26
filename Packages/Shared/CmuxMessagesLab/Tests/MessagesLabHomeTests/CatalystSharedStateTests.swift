import AppKit
import Dispatch
import os
import Testing
@testable import MessagesLabHome

/// The vendored catalyst A-L files' process-wide state, read and written from the row threads
/// (p10-stability-040): every value sits behind a lock, so concurrent use loses no update and
/// hands every thread the same held object.
@Suite struct CatalystSharedStateTests {
    static let threads = 8
    static let rounds = 5_000

    /// The counters were plain globals bumped by the measure threads: concurrent bumps were lost
    /// (or trapped in the exclusivity check). Other suites may add their own, never remove one.
    @Test func longTextCountersLoseNoConcurrentBump() {
        let before = LongTextStats.streamExtends
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            for _ in 0..<Self.rounds { LongTextStats.count(.streamExtends) }
        }
        #expect(LongTextStats.streamExtends - before >= Self.threads * Self.rounds)
    }

    /// The fold state is read by the loader queue while main expands and collapses.
    @Test func foldStateKeepsEveryConcurrentChange() {
        let ids = (0..<(Self.threads * 64)).map { "catalyst-shared-state-\($0)" }
        DispatchQueue.concurrentPerform(iterations: Self.threads) { k in
            for id in ids.dropFirst(k * 64).prefix(64) { LongTextFold.expand(id) }
        }
        #expect(ids.allSatisfy(LongTextFold.isExpanded))
        DispatchQueue.concurrentPerform(iterations: Self.threads) { k in
            for id in ids.dropFirst(k * 64).prefix(64) { LongTextFold.collapse(id) }
        }
        #expect(!ids.contains(where: LongTextFold.isExpanded))
    }

    /// The custom-row measure store's generations count every concurrent invalidation.
    @Test func customRowMeasureStoreCountsEveryBump() {
        let store = CustomRows.MeasureStore()
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            for _ in 0..<Self.rounds { store.bump("m") }
        }
        #expect(store.generation("m") == Self.threads * Self.rounds)
        let key = CustomRows.MeasureKey(id: "m", part: 0, version: 1, width: 400, generation: store.generation("m"))
        store.put(key, CGSize(width: 10, height: 20))
        #expect(store.get(key) == CGSize(width: 10, height: 20))
    }

    /// The body, code and sized fonts are made once and held: every thread gets the same instance
    /// (a font made and dropped per thread is what came back nil under concurrency, cx-qpqs).
    @Test func fontsAreHeldOncePerProcess() {
        let seen = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())
        DispatchQueue.concurrentPerform(iterations: Self.threads) { _ in
            let ids = [ObjectIdentifier(HomeFonts.body), ObjectIdentifier(Fixture.bodyFont)]
            let code = ObjectIdentifier(HomeFonts.code)
            let sized = ObjectIdentifier(HomeFonts.system(ofSize: 17.37, weight: .medium))
            seen.withLock { $0.formUnion(ids + [code, sized]) }
        }
        #expect(seen.withLock { $0.count } == 3, "body (Fixture.bodyFont is it), code and the sized font")
        #expect(Fixture.bodyFont.pointSize == 13)
        #expect(HomeFonts.code.pointSize == Fixture.bodyFont.pointSize - 1)
        #expect(HomeFonts.code.isFixedPitch)
    }
}
