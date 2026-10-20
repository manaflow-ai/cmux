import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import enum CmuxNextDaemon.TabKind
@testable import CmuxNextLayout
import CmuxNextTabs
import Testing

/// Tab drops behave as bonsplit's do in classic cmux (#22287): the edge bands, the corners, no
/// split dwell, the shared edge of a terminal tab's neighbor, a drop on the tab's own pane, and
/// the split of a pane with its only tab.
@MainActor
struct BonsplitDropParityTests {
    // MARK: Zones

    /// bonsplit's band is `max(80, 0.25 * extent)` with no cap; the third keeps a center to join.
    @Test func edgeBandsAreBonsplitsQuarterWithAnEightyPointFloor() {
        let style = LayoutStyle()
        #expect(DropZoneGeometry.band(for: 1000, style: style) == 250)
        #expect(DropZoneGeometry.band(for: 600, style: style) == 150)
        #expect(DropZoneGeometry.band(for: 300, style: style) == 80)
        #expect(DropZoneGeometry.band(for: 180, style: style) == 60)
        #expect(LayoutTunables.dropEdgeMinimum.defaultValue == 80)
        #expect(LayoutTunables.dropEdgeMaximum.defaultValue == 0)
    }

    /// In a corner left and right win over top and bottom, even nearer the top.
    @Test func leftAndRightTakeTheCorners() {
        let style = LayoutStyle()
        let pane = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 30, y: 5), in: pane, style: style) == .left)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 970, y: 595), in: pane, style: style) == .right)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 500, y: 5), in: pane, style: style) == .top)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 500, y: 595), in: pane, style: style) == .bottom)
        #expect(DropZoneGeometry.zone(at: CGPoint(x: 500, y: 300), in: pane, style: style) == .center)
    }

    /// The preview is classic's: the half the split gives, inset 4 pt on its outer sides.
    @Test func edgePreviewIsTheInsetHalf() {
        let body = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(DropZoneGeometry.classicPaneHighlight(body: body, zone: .left) == CGRect(x: 4, y: 4, width: 196, height: 192))
        #expect(DropZoneGeometry.classicPaneHighlight(body: body, zone: .bottom) == CGRect(x: 4, y: 100, width: 392, height: 96))
        #expect(DropZoneGeometry.classicPaneHighlight(body: body, zone: .center) == CGRect(x: 4, y: 4, width: 392, height: 192))
    }

    /// bonsplit splits at once; the dwell stays a Debug Settings choice that is off by default.
    @Test func splitZonesArmWithoutADwell() {
        #expect(DragTunables.splitDwell.defaultValue == 0)
    }

    // MARK: Shared edge

    /// A terminal dragged out of the left pane joins the right pane on its facing (left) edge;
    /// the right pane's outer edge still splits, and a drag from no pane splits as before.
    @Test func theFacingEdgeOfTheNeighborJoinsIt() {
        let frames: [PaneID: CGRect] = ["p1": CGRect(x: 0, y: 0, width: 500, height: 600),
                                        "p2": CGRect(x: 500, y: 0, width: 500, height: 600)]
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("p2", .left), from: "p1", frames: frames) == .pane("p2", .center))
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("p1", .right), from: "p2", frames: frames) == .pane("p1", .center))
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("p2", .right), from: "p1", frames: frames) == .pane("p2", .right))
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("p2", .left), from: nil, frames: frames) == .pane("p2", .left))
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("p1", .left), from: "p1", frames: frames) == .pane("p1", .left))
    }

    /// Only left and right edges join (bonsplit), and only the pane right beside the source.
    @Test func otherEdgesAndFartherPanesStillSplit() {
        let frames: [PaneID: CGRect] = ["top": CGRect(x: 0, y: 0, width: 1000, height: 300),
                                        "bottom": CGRect(x: 0, y: 300, width: 1000, height: 300)]
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("bottom", .top), from: "top", frames: frames) == .pane("bottom", .top))
        let row: [PaneID: CGRect] = ["a": CGRect(x: 0, y: 0, width: 300, height: 600), "b": CGRect(x: 300, y: 0, width: 300, height: 600),
                                     "c": CGRect(x: 600, y: 0, width: 300, height: 600)]
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("c", .left), from: "a", frames: row) == .pane("c", .left))
    }

    /// End to end through the layout's drag API, which the App's drop target drives.
    @Test func theLayoutDragPreviewsTheJoinAndSplitsWithoutIt() throws {
        let window = Window()
        defer { window.window.orderOut(nil) }
        let p2 = try #require(window.root.frame(of: "p2"))
        let nearLeft = window.root.convert(CGPoint(x: p2.minX + 40, y: p2.midY), to: nil)
        #expect(window.root.updateTabDrag("t", locationInWindow: nearLeft) == .pane("p2", .left))
        #expect(window.root.updateTabDrag("t", locationInWindow: nearLeft, joinsFrom: "p1") == .pane("p2", .center))
        let nearRight = window.root.convert(CGPoint(x: p2.maxX - 40, y: p2.midY), to: nil)
        #expect(window.root.updateTabDrag("t", locationInWindow: nearRight, joinsFrom: "p1") == .pane("p2", .right))
        window.root.cancelTabDrag()
        #expect(window.root.tabDragHighlightOnScreen == nil)
    }

    // MARK: Own pane

    /// A tab dropped on its own pane's body names its own slot: the resolver previews a stay and
    /// the drop changes nothing (it used to move the tab to the end of its strip).
    @Test func aDropOnItsOwnPaneBodyStays() throws {
        let tabs = ["a", "b", "c"].map { CmuxNextTabs.TabItem(id: StripTabID($0), title: $0) }
        let place = try #require(LayoutTabDropTarget.ownPlace(of: [StripTabID("a")], keepsGroup: true, in: tabs))
        #expect(place.index == 0)
        let strip = UUID()
        let context = TabDragContext(sourcePaneID: "p1", sourcePaneTabCount: 3, sourceWorkspaceID: "w", sourceWorkspaceTabCount: 3,
                                     draggedTabCount: 1, sourceStripID: strip, sourceIndex: 0)
        let proposal = TabDropProposal(kind: .strip(stripID: strip, index: place.index, groupID: place.group), highlightFrame: .zero)
        let resolution = TabDragResolver.resolve(proposal, insideWindow: true, screenPoint: .zero, context: context)
        #expect(resolution.outcome == .cancel)
        #expect(resolution.preview == .stay(proposal))
        // Another pane's body still takes the tab at its end.
        #expect(LayoutTabDropTarget.ownPlace(of: [StripTabID("z")], keepsGroup: true, in: tabs) == nil)
    }

    @Test func aTabKeepsItsGroupAndAGroupDragKeepsNone() throws {
        let group = CmuxNextTabs.TabGroupID("g")
        let tabs = [CmuxNextTabs.TabItem(id: StripTabID("a"), title: "a"), CmuxNextTabs.TabItem(id: StripTabID("b"), title: "b", groupID: group)]
        #expect(try #require(LayoutTabDropTarget.ownPlace(of: [StripTabID("b")], keepsGroup: true, in: tabs)).group == group.rawValue)
        let groupPlace = try #require(LayoutTabDropTarget.ownPlace(of: [StripTabID("b")], keepsGroup: false, in: tabs))
        #expect(groupPlace.index == 1 && groupPlace.group == nil)
    }

    // MARK: Last tab

    /// Splitting a pane with its only tab leaves a fresh tab there, as classic cmux replaces
    /// bonsplit's placeholder with a terminal; only conversation tabs refuse.
    @Test func everyKindButAConversationSplitsItsOnlyPane() {
        #expect(TabMoves.splitLeftover(for: .pty) == .sameKind)
        #expect(TabMoves.splitLeftover(for: .browser) == .sameKind)
        #expect(TabMoves.splitLeftover(for: .remoteTerminal) == .terminal)
        #expect(TabMoves.splitLeftover(for: .other("diff")) == .terminal)
        #expect(TabMoves.splitLeftover(for: .conversation) == .nothing)
    }

    // MARK: Harness

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Window {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let root: LayoutRootView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
        }
    }
}
