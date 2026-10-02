import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// niri's restore point (activate_prev_column_on_removal): closing the
/// column just opened right of the focused one puts back the offset from
/// before the open, but only when that column was focused and its close
/// moved focus back. Found by ColumnScrollCloseModelCheckTests (S3): after
/// the user went back to the previous column, a close of the opened
/// column (Cmd-W on it later, the CLI, another client) still restored the
/// old offset and threw the focused column across the screen.
struct ColumnScrollRestoreTests {
    /// c0 (full width), c1 focused at rest, then c2 opened right of c1.
    func opened() -> (ColumnScrollState, ColumnStrip) {
        let before = makeStrip([1000, 550, 550], ids: ["0", "1", "3"])
        var state = settledState(before, focused: "p1")
        let after = makeStrip([1000, 550, 550, 550], ids: ["0", "1", "2", "3"])
        state.reduce(.sync(after, focused: PaneID("p2"), source: .keyboard, animated: false))
        return (state, after)
    }

    @Test func closingTheFocusedJustOpenedColumnRestoresTheOffset() {
        let before = makeStrip([1000, 550, 550], ids: ["0", "1", "3"])
        let start = settledState(before, focused: "p1").spring.target
        var (state, _) = opened()
        state.reduce(.sync(before, focused: PaneID("p1"), source: .programmatic, animated: false))
        #expect(state.spring.target == start)
    }

    @Test func closingTheJustOpenedColumnAfterGoingBackDoesNotScroll() {
        var (state, strip) = opened()
        state.reduce(.sync(strip, focused: PaneID("p1"), source: .keyboard, animated: false))
        let x = state.screenX(of: "c1")
        state.reduce(.sync(makeStrip([1000, 550, 550], ids: ["0", "1", "3"]), focused: PaneID("p1"),
                           source: .programmatic, animated: false))
        #expect(state.screenX(of: "c1") == x)
    }
}
