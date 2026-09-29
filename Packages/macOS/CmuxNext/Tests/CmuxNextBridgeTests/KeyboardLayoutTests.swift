import CmuxNextLayout
import Testing
@testable import CmuxNextBridge

/// Pure keyboard layout math behind the pane, column, and tab group handlers.
struct KeyboardLayoutTests {
    // left | (top / bottom), horizontal split h at 0.5, vertical v at 0.5.
    let tree = SplitNode.split("h", axis: .horizontal, ratio: 0.5,
                               a: .leaf("left"),
                               b: .split("v", axis: .vertical, ratio: 0.5, a: .leaf("top"), b: .leaf("bottom")))

    @Test func resizeMovesTheNearestDividerOnTheAxis() {
        let layout = ScreenLayout.splits(tree)
        #expect(PaneResize.change(for: "bottom", direction: .up, in: layout) == .splitRatio("v", 0.45))
        #expect(PaneResize.change(for: "bottom", direction: .left, in: layout) == .splitRatio("h", 0.45))
        #expect(PaneResize.change(for: "left", direction: .right, in: layout) == .splitRatio("h", 0.55))
        #expect(PaneResize.change(for: "left", direction: .up, in: layout) == nil)
    }

    @Test func resizeClampsAtTheRatioRange() {
        let edge = ScreenLayout.splits(.split("h", axis: .horizontal, ratio: 0.95, a: .leaf("a"), b: .leaf("b")))
        #expect(PaneResize.change(for: "a", direction: .right, in: edge) == nil)
    }

    @Test func columnsResizeWidthWhenNoSplitInTheColumn() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
            LayoutColumn(id: "c2", width: 0.5, root: tree),
        ])
        #expect(PaneResize.change(for: "a", direction: .right, in: layout) == .columnWidth("c1", 0.55))
        #expect(PaneResize.change(for: "top", direction: .left, in: layout) == .splitRatio("h", 0.45))
        #expect(PaneResize.adjacentColumn(of: "a", forward: true, in: layout)?.id == "c2")
        #expect(PaneResize.adjacentColumn(of: "a", forward: false, in: layout) == nil)
    }

    @Test func groupReorderStepsOverWholeNeighborGroups() {
        typealias Slot = TabGroupReorder.Slot
        let slots = [Slot(group: nil, pinned: true), Slot(group: nil), Slot(group: "g"), Slot(group: "g"),
                     Slot(group: "h"), Slot(group: "h"), Slot(group: nil)]
        // Without g: [pin, t, h, h, t]; g sits at 2.
        #expect(TabGroupReorder.targetIndex(of: "g", forward: false, in: slots) == 1)
        #expect(TabGroupReorder.targetIndex(of: "g", forward: true, in: slots) == 4)
        #expect(TabGroupReorder.targetIndex(of: "h", forward: true, in: slots) == 5)
        #expect(TabGroupReorder.targetIndex(of: "h", forward: false, in: slots) == 2)
        let atPinned = [Slot(group: nil, pinned: true), Slot(group: "g")]
        #expect(TabGroupReorder.targetIndex(of: "g", forward: false, in: atPinned) == nil)
        #expect(TabGroupReorder.targetIndex(of: "g", forward: true, in: atPinned) == nil)
    }

    @Test func closedTabsAreRecordedOnlyWhileTheirWorkspaceLives() {
        typealias Record = ClosedTabHistory.Record
        var history = ClosedTabHistory(capacity: 2)
        let a = Record(kind: .terminal, tabID: "a", paneID: "p", workspaceID: "w1", index: 0, cwd: "/tmp")
        let b = Record(kind: .browser, tabID: "b", paneID: "p", workspaceID: "w1", index: 1, url: "https://example.com")
        let c = Record(kind: .terminal, tabID: "c", paneID: "q", workspaceID: "w2", index: 0)
        history.observe([a, b, c], liveWorkspaces: ["w1", "w2"])
        #expect(history.closed.isEmpty)

        var movedB = b
        movedB.paneID = "q"
        history.observe([a, movedB], liveWorkspaces: ["w1"])
        #expect(history.closed.isEmpty, "a move is not a close; a closed workspace is not a tab close")

        history.observe([movedB], liveWorkspaces: ["w1"])
        #expect(history.popLast() == a)
        #expect(history.popLast() == nil)
    }
}
