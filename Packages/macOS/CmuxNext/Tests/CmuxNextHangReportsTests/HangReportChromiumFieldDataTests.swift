@testable import CmuxNextHangReports
import CmuxNextMetrics
import Testing

@Suite struct HangReportChromiumFieldDataTests {
    /// Chromium's own histograms (p09-observability task 107) go in `histograms[]` as unit `chromium` with `max` 0, each
    /// bucket index the bucket's smallest sample, as web/services/hangReports/histogramCatalog.ts reads them (no layout
    /// check for Chromium's layout); a report that sent them marks them sent.
    @Test func chromiumHistogramsGoInChromiumsOwnBucketsAndAreMarkedSent() throws {
        let (store, metrics) = HangReportWireFormatTests.metrics([.mainTurn])
        metrics.record(.mainTurn, 100)
        store.foldChromium(.keyPressedLatency, count: 3, sum: 50_000,
                           buckets: [.init(minimum: 12_000, count: 2), .init(minimum: 24_000, count: 1)])
        let delta = store.delta()
        let histograms = HangReportBuilder.fieldData(delta).histograms
        let key = try #require(histograms.first { $0.name == "chromium.EventLatency.KeyPressed.TotalLatency" })
        #expect(key.unit == "chromium" && key.max == 0)
        #expect(key.buckets == [.init(index: 12_000, count: 2), .init(index: 24_000, count: 1)])
        #expect(key.count == 3 && key.sum == 50_000)
        #expect(HangReport.histogramCatalog.contains(key.name))

        store.markLogged(HangReportBuilder.sentDelta(delta, histograms: histograms))
        #expect(store.delta().isEmpty)
    }
}
