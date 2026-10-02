import CmuxNextDaemon
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

/// User requirement 2026-10-02: "i should be able to drag tab to
/// right/left/top/bottom pane, even if its the only one, and it should
/// make a dupe of the previous one i was on. just dupe type". A split of
/// the tab's own pane with its only tab moves the tab into the new pane and
/// spawns a new tab of the same kind in the source pane (one owner op,
/// `move-tab-to-split` with `respawn`). A drop on the tab's own place
/// stays no operation and shows no drop target.
struct OwnPaneSplitTests {
    let strip = UUID()

    func context(paneTabs: Int, respawns: Bool) -> TabDragContext {
        var context = TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: paneTabs, sourceWorkspaceID: "ws-1",
                                     sourceWorkspaceTabCount: paneTabs, draggedTabCount: 1, sourceStripID: strip, sourceIndex: 0)
        context.respawnsOnSplit = respawns
        return context
    }

    @Test func theOnlyTabSplitsItsOwnPaneWhenTheOwnerRespawns() {
        for edge in [TabDropEdge.left, .right, .top, .bottom] {
            #expect(TabDragResolver.accepts(.newSplit(paneID: "pane-a", edge: edge), context: context(paneTabs: 1, respawns: true)))
            #expect(!TabDragResolver.accepts(.newSplit(paneID: "pane-a", edge: edge), context: context(paneTabs: 1, respawns: false)))
            let outcome = TabDragResolver.outcome(for: TabDropProposal(kind: .newSplit(paneID: "pane-a", edge: edge), highlightFrame: .zero),
                                                  insideWindow: true, screenPoint: .zero, context: context(paneTabs: 1, respawns: true))
            #expect(outcome == .newSplit(paneID: "pane-a", edge: edge))
        }
    }

    /// The own place is not a drop target: no highlight, no inline slot,
    /// the ghost floats and a release springs back.
    @Test func theOwnPlaceIsNotADropTarget() {
        #expect(!TabDragResolver.accepts(.strip(stripID: strip, index: 1, groupID: nil), context: context(paneTabs: 1, respawns: true)))
        #expect(!TabDragResolver.accepts(.strip(stripID: strip, index: 0, groupID: nil), context: context(paneTabs: 3, respawns: true)))
        #expect(TabDragResolver.accepts(.strip(stripID: strip, index: 2, groupID: nil), context: context(paneTabs: 3, respawns: true)))
    }
}
