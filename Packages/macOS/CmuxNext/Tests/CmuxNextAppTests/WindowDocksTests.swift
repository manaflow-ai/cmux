import CoreGraphics
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import Foundation
import Testing

/// Docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md): a window's frame of edge docks, each holding an
/// ordinary workspace, around a stage that follows the sidebar. These pin the frame's rules (W1 to W8) on the pure
/// value types the window controller drives, the placement (G1 to G3) and the saved record.
@Suite
struct WindowDocksTests {
    // MARK: Model (W1, W2, W4, W5)

    @Test func oneDockPerEdgeAndDockingAnOccupiedEdgeReturnsTheWorkspaceItDisplaced() {
        var docks = WindowDocks()
        let result1 = docks.dock("ws-a", at: .left)
        #expect(result1 == nil)
        #expect(docks.dock(at: .left)?.workspace == "ws-a")
        let result2 = docks.dock("ws-b", at: .left)
        #expect(result2 == "ws-a", "W1: the old one goes back to the sidebar")
        #expect(docks.dock(at: .left)?.workspace == "ws-b")
        #expect(docks.all.count == 1)
    }

    @Test func aWorkspaceIsInOneDockOnly() {
        var docks = WindowDocks()
        _ = docks.dock("ws-a", at: .left)
        _ = docks.dock("ws-a", at: .bottom)
        #expect(docks.dock(at: .left) == nil, "W2: docking it elsewhere moves it")
        #expect(docks.edge(of: "ws-a") == .bottom)
    }

    @Test func undockRemovesTheDock() {
        var docks = WindowDocks()
        _ = docks.dock("ws-a", at: .right)
        let result3 = docks.undock("ws-a")
        #expect(result3)
        #expect(docks.all.isEmpty)
        let result4 = docks.undock("ws-a")
        #expect(!result4)
    }

    @Test func toggleHidesAndShowsAndReportsAnEmptyEdge() {
        var docks = WindowDocks()
        let result5 = docks.toggle(.top)
        #expect(result5 == .empty)
        _ = docks.dock("ws-a", at: .top)
        let result6 = docks.toggle(.top)
        #expect(result6 == .hidden)
        #expect(docks.visible.isEmpty, "a hidden dock is not placed")
        #expect(docks.dock(at: .top)?.workspace == "ws-a", "a hidden dock keeps its workspace")
        let result7 = docks.toggle(.top)
        #expect(result7 == .shown)
        #expect(docks.visible.map(\.workspace) == ["ws-a"])
    }

    @Test func revealShowsAHiddenDock() {
        var docks = WindowDocks()
        _ = docks.dock("ws-a", at: .bottom)
        _ = docks.toggle(.bottom)
        let result8 = docks.reveal("ws-a")
        #expect(result8, "W4: selecting a hidden docked workspace shows its dock")
        #expect(docks.dock(at: .bottom)?.hidden == false)
        let result9 = docks.reveal("ws-a")
        #expect(!result9, "already shown: no change")
    }

    @Test func floatingTogglesTheMode() {
        var docks = WindowDocks()
        _ = docks.dock("ws-a", at: .left)
        let result10 = docks.toggleFloating("ws-a")
        #expect(result10 == .overlay)
        let result11 = docks.toggleFloating("ws-a")
        #expect(result11 == .docked)
        let result12 = docks.toggleFloating("ws-missing")
        #expect(result12 == nil)
    }

    @Test func prunedDropsDocksOfWorkspacesThatLeft() {
        var docks = WindowDocks()
        _ = docks.dock("ws-a", at: .left)
        _ = docks.dock("ws-b", at: .right)
        docks.prune { $0 == "ws-b" }
        #expect(docks.all.map(\.workspace) == ["ws-b"], "W3")
    }

    @Test func theStageFollowsTheFocusedWorkspaceUnlessItIsDocked() {
        var docks = WindowDocks()
        _ = docks.dock("ws-dock", at: .left)
        let listed = ["ws-dock", "ws-a", "ws-b"]
        #expect(docks.stage(focused: "ws-a", previous: "ws-b", recency: [], listed: listed) == "ws-a")
        #expect(docks.stage(focused: "ws-dock", previous: "ws-b", recency: [], listed: listed) == "ws-b",
                "W5: focus in a dock keeps the stage")
        #expect(docks.stage(focused: "ws-dock", previous: nil, recency: ["ws-dock", "ws-b", "ws-a"], listed: listed) == "ws-b",
                "no stage yet: the most recent workspace that is not docked")
        #expect(docks.stage(focused: "ws-dock", previous: "ws-gone", recency: [], listed: listed) == "ws-a",
                "a stage that left the window: the first listed one not docked")
        #expect(docks.stage(focused: "ws-dock", previous: nil, recency: [], listed: ["ws-dock"]) == nil)
    }

    // MARK: Record (persistence)

    @Test func docksRoundTripThroughTheWindowRecord() throws {
        var docks = WindowDocks(orientation: .rowMajor)
        _ = docks.dock("ws-a", at: .left, mode: .overlay, extentPermille: 300)
        _ = docks.dock("ws-b", at: .bottom)
        _ = docks.toggle(.bottom)
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-c"))
        docks.store(into: &record, stage: "ws-c")
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        let restored = WindowDocks(record: decoded)
        #expect(restored == docks)
        #expect(decoded.stageKey?.rawValue == "ws-c")
        #expect(decoded.docks?.first { $0.edge == "left" }?.mode == "floating", "wire value: floating")
    }

    @Test func aRecordWithoutDocksHasNone() throws {
        let older = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w2","workspace_key":"ws-b"}"#.utf8))
        #expect(older.docks == nil)
        #expect(WindowDocks(record: older).all.isEmpty)
        var record = WindowRecord(id: "w3")
        WindowDocks().store(into: &record, stage: nil)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!json.contains("docks"), "no frame writes no field")
    }

    @Test func aRecordIgnoresUnknownEdgesAndClampsExtents() throws {
        let json = #"{"id":"w","docks":[{"edge":"diagonal","workspace_key":"ws-x","mode":"docked","extent_permille":300,"hidden":false},{"edge":"left","workspace_key":"ws-a","mode":"docked","extent_permille":5000,"hidden":false}]}"#
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(json.utf8))
        let docks = WindowDocks(record: record)
        #expect(docks.all.map(\.workspace) == ["ws-a"])
        #expect(docks.dock(at: .left)?.extentPermille == 900)
    }

    @Test func pruneDropsDocksOfDeadWorkspacesFromTheDocument() {
        var record = WindowRecord(id: "w1", workspaceKey: WorkspaceKey(rawValue: "ws-a"),
                                  workspaceKeys: [WorkspaceKey(rawValue: "ws-a"), WorkspaceKey(rawValue: "ws-b")])
        record.docks = [WindowDockRecord(edge: "left", workspaceKey: WorkspaceKey(rawValue: "ws-b"), mode: "docked",
                                         extentPermille: 300, hidden: false)]
        var document = WindowStateDocument(windows: [record])
        document.prune(liveWorkspaces: [WorkspaceKey(rawValue: "ws-a")])
        #expect(document.windows.first?.docks == nil)
    }

    // MARK: Geometry (G1 to G3, W6, W8)

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let geometry = WindowFrameGeometry(gap: 8)

    private func docks(_ items: [(String, DockEdge, DockMode, Int)], orientation: FrameOrientation = .columnMajor) -> WindowDocks {
        var docks = WindowDocks(orientation: orientation)
        for (id, edge, mode, extent) in items { _ = docks.dock(id, at: edge, mode: mode, extentPermille: extent) }
        return docks
    }

    @Test func noDocksGivesTheStageTheWholeFrame() {
        let placed = geometry.place(WindowDocks(), in: frame)
        #expect(placed.stage == frame)
        #expect(placed.docks.isEmpty)
    }

    @Test func aDockedLeftDockTakesItsShareAndTheStageTheRest() {
        let placed = geometry.place(docks([("ws-l", .left, .docked, 300)]), in: frame)
        #expect(placed.frame(of: "ws-l") == CGRect(x: 0, y: 0, width: 300, height: 800))
        #expect(placed.stage == CGRect(x: 308, y: 0, width: 692, height: 800))
    }

    @Test func columnMajorSideDocksOwnTheCornersAndBandsSpanBetweenThem() {
        let placed = geometry.place(docks([("ws-l", .left, .docked, 250), ("ws-b", .bottom, .docked, 250)]), in: frame)
        #expect(placed.frame(of: "ws-l") == CGRect(x: 0, y: 0, width: 250, height: 800))
        #expect(placed.frame(of: "ws-b") == CGRect(x: 258, y: 600, width: 742, height: 200))
        #expect(placed.stage == CGRect(x: 258, y: 0, width: 742, height: 592))
    }

    @Test func rowMajorBandsOwnTheCorners() {
        let placed = geometry.place(docks([("ws-l", .left, .docked, 250), ("ws-b", .bottom, .docked, 250)], orientation: .rowMajor),
                                    in: frame)
        #expect(placed.frame(of: "ws-b") == CGRect(x: 0, y: 600, width: 1000, height: 200))
        #expect(placed.frame(of: "ws-l") == CGRect(x: 0, y: 0, width: 250, height: 592))
        #expect(placed.stage == CGRect(x: 258, y: 0, width: 742, height: 592))
    }

    @Test func aFloatingDockNeverResizesTheStage() {
        let placed = geometry.place(docks([("ws-r", .right, .overlay, 400)]), in: frame)
        #expect(placed.stage == frame, "W8")
        #expect(placed.frame(of: "ws-r") == CGRect(x: 600, y: 0, width: 400, height: 800))
        #expect(placed.docks.first?.floating == true)
    }

    @Test func aHiddenDockIsNotPlacedAndLeavesTheStageAlone() {
        var hidden = docks([("ws-l", .left, .docked, 300)])
        _ = hidden.toggle(.left)
        let placed = geometry.place(hidden, in: frame)
        #expect(placed.stage == frame)
        #expect(placed.frame(of: "ws-l") == nil)
    }

    @Test func sharesAreClampedPerEdgeCount() {
        let one = geometry.place(docks([("ws-l", .left, .docked, 900)]), in: frame)
        #expect(one.frame(of: "ws-l")?.width == 500, "W6: one side dock at most half")
        let two = geometry.place(docks([("ws-l", .left, .docked, 900), ("ws-r", .right, .docked, 900)]), in: frame)
        #expect(two.frame(of: "ws-l")?.width == 400, "W6: two side docks at most 2/5 each")
        #expect(two.frame(of: "ws-r")?.width == 400)
        let bands = geometry.place(docks([("ws-t", .top, .docked, 900), ("ws-b", .bottom, .docked, 900)]), in: frame)
        #expect(bands.frame(of: "ws-t")?.height == 266, "W6: two bands at most 1/3 each (whole points)")
    }

    @Test func aDockNeverShrinksBelowItsMinimum() {
        let placed = geometry.place(docks([("ws-l", .left, .docked, 100)]), in: frame)
        #expect(placed.frame(of: "ws-l")?.width == WindowFrameGeometry.minimumSide)
    }

    @Test func dockAtPointFindsTheTopmostDock() {
        let placed = geometry.place(docks([("ws-r", .right, .overlay, 400), ("ws-l", .left, .docked, 300)]), in: frame)
        #expect(placed.workspace(at: CGPoint(x: 700, y: 100)) == "ws-r")
        #expect(placed.workspace(at: CGPoint(x: 100, y: 100)) == "ws-l")
        #expect(placed.workspace(at: CGPoint(x: 450, y: 100)) == nil, "the stage")
    }
}
