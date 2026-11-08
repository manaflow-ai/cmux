import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// The frame a springing pane close (Cmd-W) lands in removes no view: the closing host and the resize handle the close
/// ended leave after that frame's commit. The landing turn tore the closing host down (`LayoutViewContext.releaseRetired`
/// from the landing step): 15 ms of main thread under xctrace on cmux24, 60 of 60 closes over one 120 Hz refresh, on the
/// base and on #38608 alike (CLOSE VARIANTS 7): the views leaving the window (`removeFromSuperview`, 5 ms), their
/// deallocation in the turn's autorelease pop (5.5 ms) and the layer-tree rebuild the removal asks of the display pass
/// (`-[NSView _buildLayerTree]`, 2.8 ms). Chrome never blocks a visible frame on a teardown. The landing frame hides the
/// closing host (it shows what its removal showed); the views leave in the turn after the commit.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseLandingTurnKeepsViewsTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// Closes `pane` (focused) in the key's turn and runs its frames, each followed by its commit's work, up to the frame
    /// the motion lands in. That frame removes no view from the screen or the ring plane, and the closing host is hidden;
    /// after its commit the host, its ring and the ended handles are gone.
    static func check(_ layout: ScreenLayout, closing pane: PaneID, under: PaneID) throws {
        let rig = Rig(layout, focused: pane)
        defer { rig.close() }
        let screen = try rig.screen
        let handles = screen.dividerViews
        let (_, _, host) = try PaneCloseKeyTurnNoRestackTests.close(pane, under: under, in: rig)
        let ended = handles.filter { screen.dividerViews[$0.key] == nil }
        try #require(!ended.isEmpty, "SETUP: closing \(pane) ends no resize handle")
        // The ring plane, when the overlay sync placed the host's ring in it.
        let plane = host.chrome.superview
        func shown() -> [ObjectIdentifier] { (screen.subviews + (plane?.subviews ?? [])).map(ObjectIdentifier.init) }
        rig.commit()
        var frames = 0, landed = false
        var before: [ObjectIdentifier] = []
        while frames < 1_200 {
            before = shown()
            frames += 1
            if !rig.frame() { landed = true; break }
            rig.commit()
        }
        try #require(landed && frames > 1, "SETUP: the close's motion did not land (\(frames) frames)")
        let removed = Set(before).subtracting(shown())
        #expect(removed.isEmpty, "the landing frame removed \(removed.count) view(s) from the window (a teardown in a visible frame's turn)")
        #expect(host.superview === screen && host.isHidden, "the landing frame does not hide the closing host of \(pane)")
        for (kind, handle) in ended {
            #expect(handle.superview === screen && handle.isHidden, "the landing frame removed the ended handle \(kind)")
        }
        rig.commit()
        #expect(host.superview == nil && host.chrome.superview == nil, "the landing's commit kept the closing host of \(pane) or its ring")
        for (kind, handle) in ended {
            #expect(handle.superview == nil, "the landing's commit kept the ended handle \(kind)")
        }
    }

    /// One column split in two, Cmd-W on the second pane: its host and the split's handle leave after the landing.
    @Test func aSplitCloseLandsWithNoViewRemoved() throws {
        try Self.check(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), closing: "p2", under: "p1")
    }

    /// Three strip columns, Cmd-W on the middle one: its host and column edge leave after the landing.
    @Test func aColumnCloseLandsWithNoViewRemoved() throws {
        try Self.check(ColumnCloseScrollMotionTests.columns(3, width: 0.3), closing: "p2", under: "p1")
    }
}
