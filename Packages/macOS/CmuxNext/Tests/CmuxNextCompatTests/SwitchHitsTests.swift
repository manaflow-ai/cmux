import CmuxNextCompat
import Foundation
import Testing

/// `debug.oracle.switch_hits`'s counts: one counter per site name across instances,
/// a switch's entry sums its sites per arm, a registered site that never ran reports 0, `reset`
/// zeroes the counts after the read, a non-counting value (Release) hands out hits that count
/// nothing, and the encoded reply is the shape `switches.py --hits` reads.
@MainActor @Suite struct SwitchHitsTests {
    /// Any `String` catalog case keys a site; the raw value is what the report names.
    nonisolated private enum Switch: String {
        case layerHosting = "browser.layer-hosting"
        case cefHelper = "browser.cef-helper"
    }

    private let key = Switch.layerHosting.rawValue

    @Test func sameSiteSharesOneCounterAndTheEntrySumsSites() {
        let hits = SwitchHits(counting: true)
        let first = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown")
        let second = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown")
        let created = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageWindowCreated")
        #expect(first.key == key)
        first.ran(new: true)
        second.ran(new: true)
        created.ran(new: true)

        let entry = hits.report(reset: false).switches[key]
        #expect(entry?.old == 0)
        #expect(entry?.new == 3)
        #expect(entry?.sites == ["CEFLayerHosting.pageShown": SwitchHits.Arms(old: 0, new: 2),
                                 "CEFLayerHosting.pageWindowCreated": SwitchHits.Arms(old: 0, new: 1)])
    }

    @Test func registeredSiteThatNeverRanReportsZero() {
        let hits = SwitchHits(counting: true)
        _ = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown")
        let entry = hits.report(reset: false).switches[key]
        #expect(entry == SwitchHits.Entry(sites: ["CEFLayerHosting.pageShown": SwitchHits.Arms(old: 0, new: 0)]))
    }

    @Test func resetZeroesAfterTheRead() {
        let hits = SwitchHits(counting: true)
        hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown").ran(new: false)
        #expect(hits.report(reset: true).switches[key]?.old == 1)
        #expect(hits.report(reset: false).switches[key]?.old == 0)
    }

    @Test func noSiteNoEntry() {
        #expect(SwitchHits(counting: true).report(reset: false).switches.isEmpty)
    }

    @Test func nonCountingHandsOutUncountedHits() {
        let hits = SwitchHits(counting: false)
        let hit = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown")
        hit.ran(new: true)
        #expect(!hit.isCounted)
        #expect(hit.key == key)
        #expect(hits.report(reset: false).switches.isEmpty)
    }

    /// The reply `debug.oracle.switch_hits` sends is `Report` encoded as is. Its JSON must equal
    /// `schemas/oracle/fixtures/switch-hits-reply.json`, the report `switches.py --selftest` reads,
    /// so a renamed or re-nested field on either side fails one of the two suites.
    @Test func encodedReportMatchesTheGoldenReply() throws {
        let hits = SwitchHits(counting: true)
        let shown = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageShown")
        let created = hits.hit(Switch.layerHosting, site: "CEFLayerHosting.pageWindowCreated")
        let helper = hits.hit(Switch.cefHelper, site: "CEFEngine.start")
        for _ in 0..<2 { shown.ran(new: true) }
        created.ran(new: true)
        helper.ran(new: false)
        let report = hits.report(reset: false)

        let golden = try Self.goldenReply()
        #expect(try JSONDecoder().decode(SwitchHits.Report.self, from: golden) == report)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: golden) as? NSDictionary
        #expect(encoded != nil)
        #expect(encoded == expected)
    }

    /// The golden reply, read off the main actor's isolation (the repo root is 6 levels up).
    nonisolated private static func goldenReply() throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appending(path: "schemas/oracle/fixtures/switch-hits-reply.json"))
    }
}
