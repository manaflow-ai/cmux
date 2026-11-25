#if DEBUG
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextHibernation
import Testing

/// `debug.hover_sweep` rested about 50 ms on each tab, under the strip's 100 ms hover-load dwell
/// (`HoverWakeIntent.dwell`), so a sweep never loaded a tab on hover and could not measure that path (a1333,
/// 2026-11-24). The rest is now the `rest_ms` parameter, and by default it covers the dwell.
@MainActor @Suite struct HoverSweepRestTests {
    static let dwellMs = Double(HoverWakeIntent.dwell.components.seconds) * 1000
        + Double(HoverWakeIntent.dwell.components.attoseconds) / 1e15

    @Test func theDefaultRestCoversTheHoverLoadDwell() {
        #expect(DebugHoverSweep.restMilliseconds([:]) >= Self.dwellMs)
    }

    @Test func restMsSetsTheRest() {
        #expect(DebugHoverSweep.restMilliseconds(["rest_ms": .number(30)]) == 30)
        #expect(DebugHoverSweep.restMilliseconds(["rest_ms": .number(400)]) == 400)
    }

    @Test func aBadRestMsKeepsTheDefault() {
        let fallback = DebugHoverSweep.restMilliseconds([:])
        #expect(DebugHoverSweep.restMilliseconds(["rest_ms": .number(-5)]) == fallback)
        #expect(DebugHoverSweep.restMilliseconds(["rest_ms": .string("x")]) == fallback)
    }
}
#endif
