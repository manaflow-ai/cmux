import CmuxNextRemoteView
import CoreGraphics
@testable import CmuxNextMacScreen
import Foundation
import Testing

/// The viewer's quality readout (D10: an ultra session shows the link it spends): the host's rate, loss and encode
/// time reach every readout in one wording.
@MainActor @Suite struct MacScreenQualityReadoutTests {
    private func stats(kbps: Double? = 148_000, fps: Double = 120, target: Int? = 120, loss: Double? = 0.2) -> MacScreenSession.LiveStats {
        var stats = MacScreenSession.LiveStats()
        stats.fps = fps
        stats.targetFps = target
        stats.latencyMs = 3
        stats.hostKbps = kbps
        stats.lossPercent = loss
        stats.encodeMsP50 = 2.4
        stats.encoding = "HEVC"
        return stats
    }

    @Test func ratesReadInTheirUnit() {
        #expect(MacScreenQualityReadout.rateText(kbps: 148_000) == "148 Mbps")
        #expect(MacScreenQualityReadout.rateText(kbps: 4_200) == "4.2 Mbps")
        #expect(MacScreenQualityReadout.rateText(kbps: 850) == "850 kbps")
        #expect(MacScreenQualityReadout.rateText(kbps: .nan) == "0 kbps")
    }

    /// R1: the bar's line leads with the rate after the route; the pill says rate and round trip.
    @Test func theInlineLineLeadsWithTheRate() {
        let line = MacScreenToolbarView.statsLine(path: "Direct", kbps: 148_000, fps: 120, targetFps: 120, latencyMs: 3,
                                                  encoding: "-", frameSize: .zero)
        #expect(line == "Direct · 148 Mbps · 120/120 fps · 3 ms")
        #expect(MacScreenToolbarView.pillLine(stats()) == "148 Mbps · 3 ms")
        // A host that sends no stats keeps today's line.
        #expect(MacScreenToolbarView.pillLine(stats(kbps: nil)) == "3 ms")
    }

    /// R2 and R3 read one list: every number the host sent, in reading order.
    @Test func theReadoutListsEveryNumber() {
        let rows = MacScreenQualityReadout.rows(stats(), frameSize: CGSize(width: 3024, height: 1964), path: "Direct")
        #expect(rows.map(\.value) == ["Direct", "148 Mbps", "120/120 fps", "3 ms", "0.2%", "2.4 ms", "HEVC", "3024×1964"])
        let bare = MacScreenQualityReadout.rows(stats(kbps: nil, loss: nil), frameSize: .zero, path: "-")
        #expect(!bare.contains { $0.value.hasSuffix("Mbps") || $0.value.hasSuffix("%") })
    }

    /// The profile word comes only from what the host measured (`encode_profile`); a host too old to send it gets the
    /// rate alone, and a standard session gets no word on the bar.
    @Test func ultraIsLabelledOnlyFromTheHostsProfile() {
        #expect(MacScreenQualityReadout.rateText(kbps: 148_000, profile: "ultra") == "Ultra · 148 Mbps")
        #expect(MacScreenQualityReadout.rateText(kbps: 148_000, profile: nil) == "148 Mbps")
        #expect(MacScreenQualityReadout.rateText(kbps: 20_000, profile: "standard") == "20 Mbps")
        var ultra = stats()
        ultra.encodeProfile = "ultra"
        #expect(MacScreenToolbarView.pillLine(ultra) == "Ultra · 148 Mbps · 3 ms")
        let line = MacScreenToolbarView.statsLine(path: "Direct", kbps: 148_000, profile: "ultra", fps: 120, targetFps: 120,
                                                  latencyMs: 3, encoding: "-", frameSize: .zero)
        #expect(line == "Direct · Ultra · 148 Mbps · 120/120 fps · 3 ms")
        let rows = MacScreenQualityReadout.rows(ultra, frameSize: .zero, path: "-")
        #expect(rows.first?.value == "Ultra")
        var standard = stats()
        standard.encodeProfile = "standard"
        #expect(MacScreenQualityReadout.rows(standard, frameSize: .zero, path: "-").first?.value == "Standard")
        // No field, no row: the readout never guesses the profile from the quality it asked for.
        #expect(!MacScreenQualityReadout.rows(stats(), frameSize: .zero, path: "-").contains { $0.value == "Standard" })
    }

    /// cmux.rd/1 `stats` decodes with and without `encode_profile` (a host too old to send it).
    @Test func hostStatsDecodeTheProfileWhenSent() throws {
        let base = #"{"kbps":148000,"frames":120,"keyframes":1,"cpu_pct":30,"encode_ms_p50":2.4,"loss_pct":0.1"#
        let sent = try JSONDecoder().decode(RemoteRdHostStats.self, from: Data((base + #","encode_profile":"ultra"}"#).utf8))
        #expect(sent.encodeProfile == "ultra")
        let old = try JSONDecoder().decode(RemoteRdHostStats.self, from: Data((base + "}").utf8))
        #expect(old.encodeProfile == nil)
    }

    @Test func strainIsLossOrHalfTheFrames() {
        #expect(!MacScreenQualityReadout.isStrained(stats()))
        #expect(MacScreenQualityReadout.isStrained(stats(loss: 6)))
        #expect(MacScreenQualityReadout.isStrained(stats(fps: 50)))
        #expect(!MacScreenQualityReadout.isStrained(stats(fps: 50, target: nil)))
    }
}
