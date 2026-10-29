import CmuxNextCompat
import Foundation
import Testing

/// A guarded site's hit counts: the arm it ran lands on that arm only, an uncounted
/// hit (Release) counts nothing, and a read with `reset` starts both arms at 0. `nonisolated`: the
/// concurrent case runs its closure on worker threads (the target's default isolation is MainActor).
@Suite nonisolated struct RefactorSwitchHitTests {
    private let key = "browser.layer-hosting"
    private func arms(_ counts: (old: Int, new: Int)) -> [Int] { [counts.old, counts.new] }

    @Test func countsOnlyTheArmTheSiteRan() {
        let counter = RefactorSwitchHitCounter(key: key, site: "CEFLayerHosting.pageShown")
        let hit = RefactorSwitchHit(counter: counter)
        #expect(hit.isCounted)
        #expect(hit.key == key)
        for _ in 0..<3 { hit.ran(new: true) }
        #expect(arms(counter.read(reset: false)) == [0, 3])
        hit.ran(new: false)
        #expect(arms(counter.read(reset: false)) == [1, 3])
    }

    @Test func resetReadsThenStartsAtZero() {
        let counter = RefactorSwitchHitCounter(key: key, site: "CEFLayerHosting.pageShown")
        RefactorSwitchHit(counter: counter).ran(new: true)
        #expect(arms(counter.read(reset: true)) == [0, 1])
        #expect(arms(counter.read(reset: false)) == [0, 0])
    }

    @Test func uncountedHitCountsNothing() {
        let hit = RefactorSwitchHit(key: key)
        hit.ran(new: true)
        #expect(!hit.isCounted)
    }

    /// Sites may run off the main thread: 8 threads x 10,000 hits lose none.
    @Test func concurrentHitsAreAllCounted() {
        let counter = RefactorSwitchHitCounter(key: key, site: "Bench.site")
        let hit = RefactorSwitchHit(counter: counter)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            for _ in 0..<10_000 { hit.ran(new: index.isMultiple(of: 2)) }
        }
        #expect(arms(counter.read(reset: false)) == [40_000, 40_000])
    }
}
