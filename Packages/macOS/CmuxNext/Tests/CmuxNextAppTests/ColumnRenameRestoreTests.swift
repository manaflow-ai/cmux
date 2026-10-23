import CmuxNextLayout
import CoreGraphics
import Testing

/// The column camera across an optimistic New Column's handoff (review 1 of PL-motion-core): the
/// daemon's column takes the stand-in's over under a new id, and the restore point, the focused
/// column and the remembered panes follow it.
@MainActor
struct ColumnRenameRestoreTests {
    private static func strip(_ ids: [(ColumnID, PaneID)]) -> ColumnStrip {
        let columns = ids.enumerated().map { index, entry in
            ColumnStrip.Column(id: entry.0, frame: CGRect(x: CGFloat(index) * 616, y: 0, width: 600, height: 800), panes: [entry.1])
        }
        return ColumnStrip(columns: columns, viewportWidth: 1000, contentWidth: CGFloat(ids.count) * 616 - 16, gap: 16)
    }

    /// New Column, its daemon handoff (the stand-in's column id becomes the daemon's), then the
    /// column closes: the camera goes back where it was before the column opened. The handoff
    /// cleared the restore point (the stand-in's id left the strip), so the close only revealed
    /// the focused column.
    @Test func closingAColumnAfterItsHandoffRestoresTheCamera() {
        var state = ColumnScrollState()
        state.reduce(.sync(Self.strip([("c0", "p0"), ("c1", "p1"), ("c2", "p2")]), focused: "p1", source: .programmatic, animated: false))
        let before = state.spring.target
        state.reduce(.sync(Self.strip([("c0", "p0"), ("c1", "p1"), ("standin", "pn"), ("c2", "p2")]), focused: "pn",
                           source: .programmatic, animated: false))
        #expect(state.restore?.opened == "standin")
        #expect(state.spring.target != before, "the new column did not scroll into view")
        let opened = state.spring.target

        // The daemon's column takes the stand-in's over: same pane, new id. Nothing moves.
        state.reduce(.sync(Self.strip([("c0", "p0"), ("c1", "p1"), ("daemon", "pn"), ("c2", "p2")]), focused: "pn",
                           source: .programmatic, animated: false))
        #expect(state.restore?.opened == "daemon", "the handoff lost the restore point")
        #expect(state.restore?.column == "c1")
        #expect(state.focusedColumn == "daemon")
        #expect(state.remembered["daemon"] == "pn")
        #expect(state.spring.target == opened)

        state.reduce(.sync(Self.strip([("c0", "p0"), ("c1", "p1"), ("c2", "p2")]), focused: "p1", source: .programmatic, animated: false))
        #expect(abs(state.spring.target - before) < 0.5, "closing the column did not bring the camera back")
    }
}
