import AppKit
import CmuxNextActions
import CmuxNextFocusUI
import Testing

/// The Debug latency HUD: newest runs first, at most its row count, over-budget runs in the
/// danger color, and a reader on the monitor only while it is shown.
@MainActor
@Suite struct ActionLatencyHUDTests {
    private static func record(_ monitor: ActionBudgetMonitor, _ id: ActionID, ms: UInt64) {
        monitor.record(monitor.intern(id), .key, start: 0, end: ms * 1_000_000, inputAgeMilliseconds: -1, outcome: .committed)
    }

    @Test func theHUDShowsTheNewestRunsFirstAndMarksTheSlowOnes() {
        let monitor = ActionBudgetMonitor()
        Self.record(monitor, "fast", ms: 2)
        Self.record(monitor, "slow", ms: 30)
        let hud = ActionLatencyHUD(monitor: monitor)
        hud.show(over: nil)
        defer { hud.hide() }
        #expect(hud.rows.map(\.id) == ["slow", "fast"])
        for index in 0..<(ActionLatencyHUD.rowCount + 4) {
            hud.add(ActionTimingSample(sequence: UInt64(index), id: "x", entrypoint: .pointer, startUptimeNanos: 0, nanos: 1,
                                       inputAgeMilliseconds: -1, outcome: .committed))
        }
        #expect(hud.rows.count == ActionLatencyHUD.rowCount)
        #expect(hud.rows.first?.sequence == UInt64(ActionLatencyHUD.rowCount + 3))

        let fresh = ActionLatencyHUD(monitor: monitor)
        fresh.show(over: nil)
        defer { fresh.hide() }
        let text = fresh.text
        let slowLine = (text.string as NSString).range(of: "slow")
        let fastLine = (text.string as NSString).range(of: "fast")
        let slowColor = text.attribute(.foregroundColor, at: slowLine.location, effectiveRange: nil) as? NSColor
        let fastColor = text.attribute(.foregroundColor, at: fastLine.location, effectiveRange: nil) as? NSColor
        #expect(slowColor != nil && fastColor != nil)
        #expect(slowColor != fastColor, "the over-budget run is not marked")
    }
}
