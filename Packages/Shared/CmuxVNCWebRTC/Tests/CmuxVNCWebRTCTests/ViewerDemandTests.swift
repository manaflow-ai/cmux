@testable import CmuxVNCWebRTC
import CoreGraphics
import Foundation
import Testing

/// Viewer demand (Petal's ladder): the host captures at the smallest rung
/// that covers what the viewer shows, after the change held long enough
/// (the rules and their tests: cmux-rd-screen `demand`).
struct ViewerDemandTests {
    /// Without the rules (cmux-rd-screen `screen_demand_*`, with their tests) a host
    /// captures the full display: no cap, the size unchanged.
    @Test func withoutTheRulesTheHostCapturesTheFullDisplay() {
        var demand = ViewerDemand()
        let changed = demand.report(longEdge: 1280, displayLongEdge: 3456, pinch: false, now: 0)
        #expect(!changed)
        #expect(demand.cap == nil)
        #expect(demand.captureCap(quality: .auto, scales: true) == nil)
        #expect(ViewerDemand.fit(CGSize(width: 3456, height: 2234), cap: 1280, rules: ScreenRules()) == CGSize(width: 3456, height: 2234))
        #expect(!RecordingBackend().scalesToDemand, "a source scales only when it says so")
    }

    /// The viewer's report goes as a `view` message the host reads, never as input.
    @Test func theReportIsAViewMessage() throws {
        let input = ScreenInput(t: ScreenStreamViewer.viewDemandMessage, d: true, i: 1280)
        let decoded = try JSONDecoder().decode(ScreenInput.self, from: JSONEncoder().encode(input))
        #expect(decoded.t == "view" && decoded.i == 1280 && decoded.d == true)
    }
}
