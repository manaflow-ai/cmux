import CmuxNextLayout
import CoreGraphics
import Testing

/// The camera keeps the anchor column (the focused column, or the column under a resize drag) where it is on screen
/// across a width change before it (column-scroll.md, step 1). The new strip can leave the camera no room for that: a
/// strip that fits its viewport has none, and a strip's ends limit it. A shift the camera's target cannot take must not
/// be given to its value either: today the value takes the whole shift and the target is clamped back, so the camera
/// springs back by the difference and the anchored column slides on after the change (#35775 review; the Command
/// column-edge drag slid 26 pt under a still pointer).
struct ColumnScrollAnchorClampTests {
    /// Columns of `widths` points, 8 pt gaps, on a viewport of `viewport` points.
    static func strip(_ widths: [CGFloat], viewport: CGFloat = 1000) -> ColumnStrip {
        var x: CGFloat = 8
        var columns: [ColumnStrip.Column] = []
        for (index, width) in widths.enumerated() {
            columns.append(ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: x, y: 0, width: width, height: 600),
                                              panes: [PaneID("p\(index)")]))
            x += width + 8
        }
        return ColumnStrip(columns: columns, viewportWidth: viewport, contentWidth: x, gap: 8)
    }

    /// The camera on `before` at rest at `offset`, focus on p0; then one animated sync to `after`, anchored on c1.
    static func anchoredSync(from before: ColumnStrip, to after: ColumnStrip, offset: CGFloat = 0) -> ColumnScrollState {
        var state = ColumnScrollState()
        state.reduce(.sync(before, focused: "p0", source: .keyboard, animated: false))
        state.spring.value = offset
        state.spring.target = offset
        state.reduce(.sync(after, focused: "p0", source: .programmatic, animated: true, reveals: false, anchor: "c1"))
        return state
    }

    @Test func aStripThatFitsGivesTheCameraNoShiftItCannotKeep() {
        // Three 300 pt columns fit 1000 pt; c0 grows 30 pt (it still fits), so c1's left edge moves 30 pt.
        let state = Self.anchoredSync(from: Self.strip([300, 300, 300]), to: Self.strip([330, 300, 300]))
        #expect(state.spring.target == 0, "the camera's target left the fitting strip's only offset: \(state.spring.target)")
        #expect(state.spring.value == state.spring.target,
                "the camera shows \(state.spring.value) pt and springs back to \(state.spring.target) pt: the anchored column slides on after the change")
    }

    @Test func aCameraWithRoomKeepsTheAnchorInPlace() {
        // Three 600 pt columns on 1000 pt: room enough for the whole 30 pt shift (the behavior the clamp must keep).
        let state = Self.anchoredSync(from: Self.strip([600, 600, 600]), to: Self.strip([630, 600, 600]), offset: 100)
        #expect(state.spring.value == 130 && state.spring.target == 130,
                "the camera is at \(state.spring.value) pt for \(state.spring.target) pt; the anchor needs 130 pt")
    }

    @Test func aCameraAtTheStartTakesOnlyTheShiftItHasRoomFor() {
        // c0 shrinks 30 pt, the camera is 10 pt from the strip's start: it takes 10 pt of the -30 pt shift, and no more.
        let state = Self.anchoredSync(from: Self.strip([600, 600, 600]), to: Self.strip([570, 600, 600]), offset: 10)
        #expect(state.spring.target == 0, "the camera's target is \(state.spring.target) pt, the strip starts at 0")
        #expect(state.spring.value == state.spring.target,
                "the camera shows \(state.spring.value) pt and springs back to \(state.spring.target) pt")
    }
}
