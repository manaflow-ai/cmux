import CmuxNextLayout
import CoreGraphics
import Testing

/// A closed column cannot leave the strip camera past the new strip (#22059 clamps it). The clamp
/// stops only a velocity that points out of the strip: a camera already coming back into it (a
/// center or a fling in flight when Cmd-W lands) keeps its speed, so the close does not stop the
/// motion dead and start it again.
struct ColumnCloseClampVelocityTests {
    /// `count` half-width columns on a 1200 pt strip, no gaps.
    static func strip(_ count: Int) -> ColumnStrip {
        let columns = (1...count).map { index in
            ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: CGFloat(index - 1) * 600, y: 0, width: 600, height: 800),
                               panes: [PaneID("p\(index)")])
        }
        return ColumnStrip(columns: columns, viewportWidth: 1200, contentWidth: CGFloat(count) * 600, gap: 0)
    }

    /// Four columns, focus on p1, the camera at `value` moving at `velocity` toward `target`.
    static func moving(value: CGFloat, velocity: CGFloat, target: CGFloat) -> ColumnScrollState {
        var state = ColumnScrollState()
        state.reduce(.sync(strip(4), focused: "p1", source: .keyboard, animated: false))
        state.spring.value = value
        state.spring.velocity = velocity
        state.spring.target = target
        return state
    }

    @Test func aCloseKeepsAVelocityBackIntoTheStrip() {
        // A center of p1 in flight: past the three-column strip's end (600), coming back at 14854 pt/s.
        var state = Self.moving(value: 845, velocity: -14_854, target: 0)
        state.reduce(.sync(Self.strip(3), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.value == 600, "the camera is not clamped into the new strip: \(state.spring.value)")
        #expect(state.spring.velocity == -14_854, "the close stopped the camera: \(state.spring.velocity) pt/s")
    }

    @Test func aCloseStopsAVelocityOutOfTheStrip() {
        var state = Self.moving(value: 845, velocity: 3_000, target: 1_200)
        state.reduce(.sync(Self.strip(3), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.value == 600)
        #expect(state.spring.velocity == 0, "the camera still moves past the strip's end at \(state.spring.velocity) pt/s")
    }

    /// Two half-width columns fit the window: a camera coming back toward 0 would pass the leading
    /// edge (with pane motion off, nothing carries the panes to hide it), so it stops at 0.
    @Test func aCloseToAStripThatFitsStopsTheCameraAtZero() {
        var state = Self.moving(value: 845, velocity: -14_854, target: 0)
        state.reduce(.sync(Self.strip(2), focused: "p1", source: .programmatic, animated: true))
        #expect(state.spring.value == 0)
        #expect(state.spring.velocity == 0, "the camera moves past the leading edge at \(state.spring.velocity) pt/s")
    }
}
