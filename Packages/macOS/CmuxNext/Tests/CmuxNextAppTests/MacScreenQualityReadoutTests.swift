import CoreGraphics
@testable import CmuxNextMacScreen
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

    @Test func strainIsLossOrHalfTheFrames() {
        #expect(!MacScreenQualityReadout.isStrained(stats()))
        #expect(MacScreenQualityReadout.isStrained(stats(loss: 6)))
        #expect(MacScreenQualityReadout.isStrained(stats(fps: 50)))
        #expect(!MacScreenQualityReadout.isStrained(stats(fps: 50, target: nil)))
    }
}
