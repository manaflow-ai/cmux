import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextTestSupport
import enum CmuxNextDaemon.PaneEdge
@testable import CmuxNextLayout
import CmuxNextTabs
import Testing

/// Tab drops behave as bonsplit's do in classic cmux (#22287): no split dwell, the shared edge of
/// a terminal tab's neighbor, a drop on the tab's own pane, the split of a pane with its only tab,
/// even split sizing, and no flicker. Band size and corners follow plans/cmux-next/drop-zones/DESIGN.md
/// (`DropZoneRuleTests`).
@MainActor
@Suite(.closesItsWindows)
struct BonsplitDropParityTests {
    // MARK: Zones

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
        // A pane right of the source but beside none of it shares no edge: it splits.
        let offset: [PaneID: CGRect] = ["a": CGRect(x: 0, y: 0, width: 300, height: 300), "b": CGRect(x: 300, y: 300, width: 300, height: 300)]
        #expect(DropZoneGeometry.joiningSharedEdge(.pane("b", .left), from: "a", frames: offset) == .pane("b", .left))
    }

    /// End to end through the layout's drag API, which the App's drop target drives.
    @Test func theLayoutDragPreviewsTheJoinAndSplitsWithoutIt() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
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
        let place = try #require(TabDragPayload.tab(id: "a", sourceStripID: UUID()).ownPlace(in: tabs))
        #expect(place.index == 0)
        let strip = UUID()
        let context = TabDragContext(sourcePaneID: "p1", sourcePaneTabCount: 3, sourceWorkspaceID: "w", sourceWorkspaceTabCount: 3,
                                     draggedTabCount: 1, sourceStripID: strip, sourceIndex: 0)
        let proposal = TabDropProposal(kind: .strip(stripID: strip, index: place.index, groupID: place.group), highlightFrame: .zero)
        let resolution = TabDragResolver.resolve(proposal, insideWindow: true, screenPoint: .zero, context: context)
        #expect(resolution.outcome == .cancel)
        #expect(resolution.preview == .stay(proposal))
        // Another pane's body still takes the tab at its end.
        #expect(TabDragPayload.tab(id: "z", sourceStripID: UUID()).ownPlace(in: tabs) == nil)
    }

    @Test func aTabKeepsItsGroupAndAGroupDragKeepsNone() throws {
        let group = CmuxNextTabs.TabGroupID("g")
        let tabs = [CmuxNextTabs.TabItem(id: StripTabID("a"), title: "a"), CmuxNextTabs.TabItem(id: StripTabID("b"), title: "b", groupID: group)]
        #expect(try #require(TabDragPayload.tab(id: "b", sourceStripID: UUID()).ownPlace(in: tabs)).group == group.rawValue)
        let groupPlace = try #require(TabDragPayload.tabGroup(id: "g", tabIDs: ["b"], sourceStripID: UUID(), width: 80).ownPlace(in: tabs))
        #expect(groupPlace.index == 1 && groupPlace.group == nil)
    }

    // MARK: Last tab

    /// A pane's only tab dropped on its own edge is never refused (classic shows the zone and fills
    /// the pane it leaves): the tab stays and the New Tab page opens on the far side.
    @Test func aLoneTabOnItsOwnEdgeIsAlwaysATarget() {
        let context = TabDragContext(sourcePaneID: "p1", sourcePaneTabCount: 1, sourceWorkspaceID: "w", sourceWorkspaceTabCount: 2,
                                     draggedTabCount: 1)
        #expect(TabDragResolver.verdict(.newSplit(paneID: "p1", edge: .left), context: context) == .accept)
        #expect(context.splitsBehind(pane: "p1") && !context.splitsBehind(pane: "p2"))
        let busy = TabDragContext(sourcePaneID: "p1", sourcePaneTabCount: 2, sourceWorkspaceID: "w", sourceWorkspaceTabCount: 2,
                                  draggedTabCount: 1)
        #expect(!busy.splitsBehind(pane: "p1"))
    }

    /// The New Tab page opens across the pane from the drop edge.
    @Test func theSplitBehindOpensOnTheFarSide() {
        #expect(PaneEdge.left.opposite == .right && PaneEdge.right.opposite == .left)
        #expect(PaneEdge.top.opposite == .bottom && PaneEdge.bottom.opposite == .top)
    }

    /// A target the App refuses stays hidden while the pointer stays on it, instead of drawing and
    /// hiding again on every move (the reported flicker), and the next target draws.
    @Test func aRefusedTargetStaysHiddenUntilTheTargetChanges() throws {
        let window = Window()
        defer { window.window.closeAfterTest() }
        let p2 = try #require(window.root.frame(of: "p2"))
        let nearLeft = window.root.convert(CGPoint(x: p2.minX + 40, y: p2.midY), to: nil)
        #expect(window.root.updateTabDrag("t", locationInWindow: nearLeft) == .pane("p2", .left))
        #expect(window.root.tabDragHighlightOnScreen != nil)
        window.root.hideTabDragHighlight()
        let nudged = CGPoint(x: nearLeft.x + 2, y: nearLeft.y + 2)
        #expect(window.root.updateTabDrag("t", locationInWindow: nudged) == .pane("p2", .left))
        #expect(window.root.tabDragHighlightOnScreen == nil)
        let center = window.root.convert(CGPoint(x: p2.midX, y: p2.midY), to: nil)
        #expect(window.root.updateTabDrag("t", locationInWindow: center) == .pane("p2", .center))
        #expect(window.root.tabDragHighlightOnScreen != nil)
        window.root.cancelTabDrag()
    }

    // MARK: Even splits

    /// A drop that splits B in A|B gives three equal panes with `layout.splitSizing` even, as a
    /// keyboard split does (it used to leave A 50%, B 25%, new 25%).
    @Test func aDropSplitEvensThePanesAlongItsAxis() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))))], activeScreenID: "s", focusedPane: "a")
        model.splitSizingOverride = .even
        let changes = model.splitSizingChanges(splitting: "b", axis: .horizontal)
        #expect(changes.count == 1 && changes.first?.split == "x")
        #expect(abs((changes.first?.ratio ?? 0) - 1.0 / 3) < 1e-9)
        model.splitSizingOverride = .halve
        #expect(model.splitSizingChanges(splitting: "b", axis: .horizontal).isEmpty)
    }

    /// The pane the drop empties closes in the same move: the even shares leave it out, as the
    /// drop preview does (`DropPreviewLayout` with even sizing).
    @Test func aDropSplitEvensWithoutThePaneItEmpties() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                   b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))))], activeScreenID: "s", focusedPane: "a")
        model.splitSizingOverride = .even
        // Without the emptied pane `a`, splitting `c` leaves b, c and the new pane a third each.
        let changes = model.splitSizingChanges(splitting: "c", axis: .horizontal, removing: "a")
        #expect(changes.map(\.split) == ["y"])
        #expect(abs((changes.first?.ratio ?? 0) - 1.0 / 3) < 1e-9)
        let preview = DropPreviewLayout(splitting: "c", zone: .right, in: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                   b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))), removing: "a", evenSizing: true)
        guard case let .splits(.split(id, _, ratio, _, _))? = preview?.layout else { Issue.record("no preview"); return }
        #expect(id == "y" && abs(ratio - 1.0 / 3) < 1e-9)
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
