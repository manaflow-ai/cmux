#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// When an update settles the rows' self-sizing and restores once more (``PagedListSettle``), as
/// plain data.
struct PagedListSettleTests {
    private func again(up: Bool = true, sliding: Bool = true, scrolling: Bool = false, anchored: Bool = true,
                       drift: CGFloat) -> Bool {
        PagedListSettle.again(.init(up: up, sliding: sliding, scrolling: scrolling, anchored: anchored, drift: drift))
    }

    /// An `.up` list following its newest row, its slide running: a row above the kept one sized
    /// itself after the update's restore (an arrival measuring from its estimate, an edit), so the
    /// kept row drifted 118 pt. The update restores once more before the frame is committed (full 27
    /// af47eab9 up-slow-inserts frame #76: `U-192, r+348, c+348, m+118, m_+96`, 118 pt drawn).
    @Test func anUpSlideWhoseRowsSizedAfterTheRestoreRestoresAgain() {
        #expect(again(drift: 118))
    }

    /// An `.up` list whose update's restore ran (anchored), at rest: the rows it restored sized after
    /// it, so it restores once more (the coordinator's rule: whenever the anchored restore ran).
    @Test func anAnchoredUpdateAtRestRestoresAgain() {
        #expect(again(sliding: false, drift: 22))
    }

    /// A `.down` list: its rows above the reader are the rows arriving at the top; restoring again
    /// would correct their move twice (af47eab9 down-medium/fast-flood 146.3, `m+54.3, m+34.3, r'+66.3`).
    @Test func aDownListNeverRestoresAgain() {
        #expect(!again(up: false, drift: 118))
    }

    /// A finger resting on the list, or a drag or a fling, after an anchored update: the first restore
    /// already moved the offset under the finger, so one more bounded restore in the same update is
    /// no more of a fight (af47eab9/633ee37a: up-slow-flood `tracking=true, r+148, m_+22`; up-medium-flood
    /// `m_+22, m_+22, d-25.3` during a drag; 22 pt each).
    @Test func underAFingerAnAnchoredUpdateRestoresAgain() {
        #expect(again(scrolling: true, drift: 22))
        #expect(again(sliding: false, scrolling: true, drift: 22))
    }

    /// Nothing drifted (within half a point): no extra pass.
    @Test func noDriftNoExtraPass() {
        #expect(!again(drift: 0.4))
    }

    /// No anchor (nothing came, went or changed around the reader): no extra pass.
    @Test func noAnchorNoExtraPass() {
        #expect(!again(anchored: false, drift: 118))
    }
}
#endif
