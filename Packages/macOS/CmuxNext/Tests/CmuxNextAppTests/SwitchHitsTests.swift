#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import CmuxNextSettings
@testable import CmuxNextApp
import Testing

/// `debug.oracle.switch_hits` (p15-oracle-027): one counter per site name across instances, the
/// report sums a switch's sites per arm, a registered site that never ran reports 0, and `reset`
/// zeroes the counts after the read.
@MainActor @Suite struct SwitchHitsTests {
    private func counts(_ value: JSONValue?) -> [Int?] {
        [value?["old"]?.intValue, value?["new"]?.intValue]
    }

    @Test func sameSiteSharesOneCounterAndTheReportSumsSites() {
        let hits = SwitchHits()
        let first = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let second = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let created = hits.hit(.layerHosting, site: "CEFLayerHosting.pageWindowCreated")
        first.ran(new: true)
        second.ran(new: true)
        created.ran(new: true)

        let entry = hits.report(reset: false)["switches"]?[RefactorSwitchKey.layerHosting.rawValue]
        #expect(counts(entry) == [0, 3])
        #expect(counts(entry?["sites"]?["CEFLayerHosting.pageShown"]) == [0, 2])
        #expect(counts(entry?["sites"]?["CEFLayerHosting.pageWindowCreated"]) == [0, 1])
    }

    @Test func registeredSiteThatNeverRanReportsZero() {
        let hits = SwitchHits()
        _ = hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown")
        let entry = hits.report(reset: false)["switches"]?[RefactorSwitchKey.layerHosting.rawValue]
        #expect(counts(entry) == [0, 0])
    }

    @Test func resetZeroesAfterTheRead() {
        let hits = SwitchHits()
        hits.hit(.layerHosting, site: "CEFLayerHosting.pageShown").ran(new: false)
        let key = RefactorSwitchKey.layerHosting.rawValue
        #expect(counts(hits.report(reset: true)["switches"]?[key]) == [1, 0])
        #expect(counts(hits.report(reset: false)["switches"]?[key]) == [0, 0])
    }

    @Test func noSiteNoEntry() {
        #expect(SwitchHits().report(reset: false)["switches"] == .object([:]))
    }
}
#endif
