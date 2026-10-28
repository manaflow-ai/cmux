@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `debug.shipping_mode` (p14-energy-100): the keys idle-budget's `shipping_fields` reads, the app's own
/// values (never a prediction), and null once the services are gone.
@Suite struct ShippingModeReportTests {
    private static let sending = ShippingModeReport.State(
        drawsWhenOccluded: false, pagesRenderWhenCovered: false, sentryShouldStart: true,
        hangReports: .init(available: true, setting: true, decision: "send", enabled: true))

    @Test func theKeysIdleBudgetReads() {
        let json = Self.sending.json
        let keys = Set((json.objectValue ?? [:]).keys)
        #expect(keys == ["draws_when_occluded", "pages_render_when_covered", "sentry_should_start", "hang_reports"])
        #expect(json["draws_when_occluded"] == .bool(false))
        #expect(json["pages_render_when_covered"] == .bool(false))
        #expect(json["sentry_should_start"] == .bool(true))
        let hangReports: JSONValue = ["available": .bool(true), "setting": .bool(true), "decision": .string("send"),
                                      "enabled": .bool(true), "daemon_metrics_fold": .null,
                                      "chromium_histograms": .null]
        #expect(json["hang_reports"] == hangReports)
    }

    @Test func aBuildThatCannotSendReportsNulls() {
        let off = ShippingModeReport.HangReports(available: false, setting: nil, decision: nil, enabled: false)
        let expected: JSONValue = ["available": .bool(false), "setting": .null, "decision": .null, "enabled": .bool(false),
                                   "daemon_metrics_fold": .null, "chromium_histograms": .null]
        #expect(off.json == expected)
    }

    /// Task 062: a report whose daemon had no metrics file is counted where a person can read it.
    @Test func theDaemonMetricsFoldCountsShow() {
        let hangReports = ShippingModeReport.HangReports(available: true, setting: true, decision: "send", enabled: true,
                                                         daemonMetricsFold: ["folded": 2, "samples": 40, "missing": 1])
        let expected: JSONValue = ["folded": .number(2), "samples": .number(40), "missing": .number(1)]
        #expect(hangReports.json["daemon_metrics_fold"] == expected)
    }

    /// Task 107: an old fork or host mode answers no Chromium histograms; the harvest's tally says unsupported, so it
    /// does not look like a Chromium with no samples.
    @Test func theChromiumHarvestCountsShow() {
        let hangReports = ShippingModeReport.HangReports(available: true, setting: true, decision: "send", enabled: true,
                                                         chromiumHistograms: ["folded": 0, "unsupported": 2])
        let expected: JSONValue = ["folded": .number(0), "unsupported": .number(2)]
        #expect(hangReports.json["chromium_histograms"] == expected)
    }

    @Test func theMethodAnswersTheReadersState() async {
        let report = ShippingModeReport { Self.sending }
        #expect(report.method.name == "debug.shipping_mode")
        #expect(await report.state() == Self.sending)
        let gone = ShippingModeReport { nil }
        #expect(await gone.state() == nil)
    }
}
