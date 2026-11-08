import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A springing pane close (Cmd-W) reorders no view in its key turn or its first frame. FRAME OWNER S3c puts the closing
/// pane's host under the live views of its rank; doing that with `sortSubviews` makes AppKit mark the window's layer tree
/// for a rebuild (`-[NSWindow _setViewsNeedBuildLayerTree]`), and the next display pass walks the whole window
/// (`-[NSView _buildLayerTree]`: 2.9 ms of the 19.3 ms close key cycle, CLOSE VARIANTS 6 diag build 0ceed0ab on cmux24,
/// 10 of 10 closes). The closing host keeps its place in the subviews; its layer's `zPosition` draws it under its
/// rank's live views, and it still draws above the views of a lower rank.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseKeyTurnNoRestackTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// The screen's subviews back to front as they draw: by layer `zPosition`, then by their order.
    static func drawOrder(_ screen: NSView) -> [NSView] {
        screen.subviews.enumerated().sorted { a, b in
            let (za, zb) = (a.element.layer?.zPosition ?? 0, b.element.layer?.zPosition ?? 0)
            return za != zb ? za < zb : a.offset < b.offset
        }.map(\.element)
    }

    /// Closes `pane` in the key's turn and runs its first frame. Returns the subviews before, the ones after, and
    /// the host of `pane`. `under`: a live pane of the closing one's rank. The hosts go in in the order of a dictionary
    /// (random per process), so the closing host is first put above that pane in the subviews: placing it under the
    /// pane by a reorder would then show in every run.
    static func close(_ pane: PaneID, under: PaneID, in rig: Rig) throws -> (before: [ObjectIdentifier], after: [ObjectIdentifier], host: PaneHostView) {
        let screen = try rig.screen
        let host = try #require(rig.root.context.hosts[pane], "SETUP: no host for \(pane)")
        let live = try #require(rig.root.context.hosts[under], "SETUP: no host for \(under)")
        if let a = screen.subviews.firstIndex(of: host), let b = screen.subviews.firstIndex(of: live), a < b {
            screen.addSubview(host, positioned: .above, relativeTo: live)
            rig.root.layoutSubtreeIfNeeded()
        }
        let (a, b) = (screen.subviews.firstIndex(of: host), screen.subviews.firstIndex(of: live))
        try #require(a != nil && b != nil && a! > b!, "SETUP: the host of \(pane) is not above \(under) in the subviews")
        let before = screen.subviews.map(ObjectIdentifier.init)
        _ = try #require(rig.model.showPaneClose(pane), "SETUP: \(pane) did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try #require(screen.closingPanes.entries[pane] != nil, "SETUP: the close of \(pane) does not spring (no closing host)")
        _ = rig.frame()
        try #require(host.superview === screen && host.showsClosingGround, "SETUP: the closing host of \(pane) left after one frame")
        return (before, screen.subviews.map(ObjectIdentifier.init), host)
    }

    /// The views in both lists keep their order: nothing moved in front of or behind another.
    static func reordered(before: [ObjectIdentifier], after: [ObjectIdentifier]) -> Bool {
        let kept = Set(before).intersection(after)
        return before.filter(kept.contains) != after.filter(kept.contains)
    }

    /// Three strip columns, Cmd-W on the middle one: its host stays where it is in the subviews and draws under both
    /// neighbours.
    @Test func aStripCloseReordersNoViewAndDrawsUnderItsNeighbours() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.columns(3, width: 0.3), focused: "p2")
        defer { rig.close() }
        let screen = try rig.screen
        let (before, after, host) = try Self.close("p2", under: "p1", in: rig)
        #expect(!Self.reordered(before: before, after: after), "the close's key turn reordered the screen's subviews (AppKit rebuilds the window's layer tree)")
        let order = Self.drawOrder(screen).map(ObjectIdentifier.init)
        let live = try ["p1", "p3"].map { try #require(rig.root.context.hosts[PaneID($0)]) }
        for neighbour in live {
            let (closing, shown) = (order.firstIndex(of: ObjectIdentifier(host)), order.firstIndex(of: ObjectIdentifier(neighbour)))
            #expect(closing != nil && shown != nil && closing! < shown!, "the closing host does not draw under \(neighbour.pane)")
        }
    }

    /// A strip pane and a docked column of two panes, Cmd-W on the lower docked one: its host stays where it is in the
    /// subviews, draws under the docked pane left and above the strip pane.
    @Test func aDockedCloseReordersNoViewAndKeepsItsRank() throws {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
            LayoutColumn(id: "dock", width: 0.3, root: .split(SplitID("d"), axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")),
                         dock: DockColumn(edge: .right, mode: .docked)),
        ])
        let rig = Rig(layout, focused: "p3")
        defer { rig.close() }
        let screen = try rig.screen
        let (before, after, host) = try Self.close("p3", under: "p2", in: rig)
        #expect(!Self.reordered(before: before, after: after), "the close's key turn reordered the screen's subviews (AppKit rebuilds the window's layer tree)")
        let order = Self.drawOrder(screen).map(ObjectIdentifier.init)
        let strip = try #require(rig.root.context.hosts["p1"]), docked = try #require(rig.root.context.hosts["p2"])
        let (closing, below, above) = (order.firstIndex(of: ObjectIdentifier(host)), order.firstIndex(of: ObjectIdentifier(strip)),
                                       order.firstIndex(of: ObjectIdentifier(docked)))
        #expect(closing != nil && below != nil && below! < closing!, "the docked closing host does not draw above the strip pane")
        #expect(closing != nil && above != nil && closing! < above!, "the docked closing host does not draw under the docked pane left")
    }
}
