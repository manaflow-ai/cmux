import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The DEBUG paint-latency overlay reads hostd's join of each paint report
/// (`paint_latency::Summary::answer`, the Rust side computes every number).
@Suite struct TerminalPaintSummaryTests {
    /// hostd's answer as `a_report_splits_into_mac_wire_and_phone` (paint_latency.rs) builds it.
    static let answer = Data("""
    {"kind":"paint-summary","at_ms":1,"samples":3,"joined":3,"offset_ms":-500.0,"clock_rtt_ms":40.0,
     "offset_error_ms":20.0,"total":{"n":3,"p50_ms":12.0,"p95_ms":57.0,"max_ms":57.0},
     "mac":{"n":3,"p50_ms":1.0,"p95_ms":2.0,"max_ms":2.0},"wire":{"n":3,"p50_ms":6.0,"p95_ms":40.0,"max_ms":40.0},
     "phone_paint":{"n":3,"p50_ms":4.0,"p95_ms":15.0,"max_ms":15.0},"last_total_ms":8.0}
    """.utf8)

    @Test func hostdsAnswerReadsIntoTheOverlaysNumbers() throws {
        let summary = try #require(TerminalPaintSummary(answer: Self.answer))
        #expect(summary.lastTotalMs == 8)
        #expect(summary.total == .init(n: 3, p50: 12, p95: 57, max: 57))
        #expect(summary.wire?.p95 == 40)
        #expect(summary.phonePaint?.p50 == 4)
        #expect(summary.offsetMs == -500)
        #expect(summary.offsetErrorMs == 20)
        #expect(summary.overlayText == "Δ  8 p50 12 p95 57 ±20.0\nmac  2 net 40 app 15")
    }

    @Test func anythingElseOnTheChannelIsNotASummary() {
        #expect(TerminalPaintSummary(answer: Data(#"{"t0":1,"t1":2,"t2":3}"#.utf8)) == nil)
        #expect(TerminalPaintSummary(answer: Data("not json".utf8)) == nil)
    }

    @Test func theOverlaysLineKeepsItsWidthBeforeAndAfterNumbers() {
        // Fixed width: the label never shifts as numbers come and go.
        let empty = TerminalPaintSummary().overlayText
        let full = TerminalPaintSummary(lastTotalMs: 123, total: .init(n: 1, p50: 45, p95: 678, max: 678),
                                        offsetErrorMs: 1.5).overlayText
        #expect(empty == "Δ  – p50  – p95  – ±?\nmac  – net  – app  –")
        #expect(full == "Δ123 p50 45 p95678 ±1.5\nmac  – net  – app  –")
    }

    @Test func theOverlayReportsEachSecondNotEachFive() {
        var tally = TerminalPaintTally(reportIntervalMs: TerminalPaintOverlay.reportEveryMs)
        tally.handed(1)
        tally.mark(seq: 1, receivedMs: 0)
        tally.presented(parsed: 1, atMs: 5)
        #expect(tally.takeReport(nowMs: 500) == nil)
        #expect(tally.takeReport(nowMs: 1005)?.count == 1)
        #expect(TerminalPaintOverlay.enabled == false, "off unless asked for")
    }
}

#if os(iOS)
/// Projection is the default terminal (#49901), and it wraps the Mac's session: a paint report
/// the screen makes must reach that session, or the Mac never hears one.
@MainActor
@Suite struct TerminalProjectingPaintReportTests {
    @Test func aPaintReportGoesThroughTheProjectionToTheMacsSession() {
        let mac = MockTerminalSession(playsIntro: false)
        let session = TerminalProjectingSession(inner: mac)
        session.reportPaint([[1, 10, 14]])
        #expect(mac.paintSamples == [[1, 10, 14]])
    }
}
#endif
