import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A springing pane close (Cmd-W) removes no view from the screen in its key turn or its first frame. The close ends a
/// split or a column edge, and its resize handle left the screen with `removeFromSuperview` in the key turn: AppKit marks
/// the window's layer tree for a rebuild (`-[NSWindow _setViewsNeedBuildLayerTree]`), and the key's display pass walks
/// the whole window (`-[NSView _buildLayerTree]`, 2.7 to 2.8 ms of the 22 ms close key cycle: CLOSE VARIANTS 7, diag build
/// adc2da47 on cmux24, 10 of 10 closes, the only mark left once the closing host is not reordered). The handle hides in
/// the key turn and goes when the motion lands, with the closing host (one layer-tree rebuild in the landing frame, as
/// before).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseKeyTurnKeepsViewsTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// Closes `pane` (focused) in the key's turn, runs its first frame, then lands the motion. In the key turn and the
    /// first frame no view leaves the screen, and every handle the close ended is hidden; once the landing frame
    /// committed, those handles and the closing host are gone.
    static func check(_ layout: ScreenLayout, closing pane: PaneID, under: PaneID) throws {
        let rig = Rig(layout, focused: pane)
        defer { rig.close() }
        let screen = try rig.screen
        let handles = screen.dividerViews
        let (before, after, host) = try PaneCloseKeyTurnNoRestackTests.close(pane, under: under, in: rig)
        let ended = handles.filter { screen.dividerViews[$0.key] == nil }
        try #require(!ended.isEmpty, "SETUP: closing \(pane) ends no resize handle")
        let removed = Set(before).subtracting(after)
        #expect(removed.isEmpty, "the close's key turn removed \(removed.count) view(s) from the screen (AppKit rebuilds the window's layer tree)")
        for (kind, handle) in ended {
            #expect(handle.superview === screen && handle.isHidden, "the ended handle \(kind) does not stay on the screen hidden until the landing")
        }
        var frames = 0
        while rig.frame(), frames < 1_200 { frames += 1 }
        try #require(frames < 1_200, "SETUP: the close's motion did not land")
        rig.commit() // the landing frame committed: its views leave (PaneCloseLandingTurnKeepsViewsTests)
        #expect(host.superview == nil, "the landing kept the closing host of \(pane)")
        for (kind, handle) in ended {
            #expect(handle.superview == nil, "the landing kept the ended handle \(kind)")
        }
    }

    /// One column split in two, Cmd-W on the second pane: the split's handle hides, and goes at the landing.
    @Test func aSplitCloseRemovesNoViewInItsKeyTurn() throws {
        try Self.check(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), closing: "p2", under: "p1")
    }

    /// Three strip columns, Cmd-W on the middle one: its column edge hides, and goes at the landing.
    @Test func aColumnCloseRemovesNoViewInItsKeyTurn() throws {
        try Self.check(ColumnCloseScrollMotionTests.columns(3, width: 0.3), closing: "p2", under: "p1")
    }
}
