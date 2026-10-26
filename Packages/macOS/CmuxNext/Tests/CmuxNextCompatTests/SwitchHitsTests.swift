import CmuxNextCompat
import Testing

/// `debug.oracle.switch_hits`'s counts (p15-oracle-027): one counter per site name across instances,
/// a switch's entry sums its sites per arm, a registered site that never ran reports 0, `reset`
/// zeroes the counts after the read, and a non-counting value (Release) hands out hits that count
/// nothing.
@MainActor @Suite struct SwitchHitsTests {
    private let key = RefactorSwitchKey.layerHosting.rawValue

    @Test func sameSiteSharesOneCounterAndTheEntrySumsSites() {
        let hits = SwitchHits(counting: true)
        let first = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let second = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let created = hits.hit(.layerHosting, site: "CEFLayerHosting.pageWindowCreated")
        first.ran(new: true)
        second.ran(new: true)
        created.ran(new: true)

        let entry = hits.report(reset: false)[key]
        #expect(entry?.old == 0)
        #expect(entry?.new == 3)
        #expect(entry?.sites == ["CEFLayerHosting.pageShown": SwitchHits.Arms(old: 0, new: 2),
                                 "CEFLayerHosting.pageWindowCreated": SwitchHits.Arms(old: 0, new: 1)])
    }

    @Test func registeredSiteThatNeverRanReportsZero() {
        let hits = SwitchHits(counting: true)
        _ = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let entry = hits.report(reset: false)[key]
        #expect(entry?.old == 0)
        #expect(entry?.new == 0)
        #expect(entry?.sites == ["CEFLayerHosting.pageShown": SwitchHits.Arms(old: 0, new: 0)])
    }

    @Test func resetZeroesAfterTheRead() {
        let hits = SwitchHits(counting: true)
        hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown").ran(new: false)
        #expect(hits.report(reset: true)[key]?.old == 1)
        #expect(hits.report(reset: false)[key]?.old == 0)
    }

    @Test func noSiteNoEntry() {
        #expect(SwitchHits(counting: true).report(reset: false).isEmpty)
    }

    @Test func nonCountingHandsOutUncountedHits() {
        let hits = SwitchHits(counting: false)
        let hit = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        hit.ran(new: true)
        #expect(!hit.isCounted)
        #expect(hits.report(reset: false).isEmpty)
    }
}
