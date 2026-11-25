import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileModel

/// A grid card's split map (`WorkspaceLayout.splitMap(ofTab:)`): the Mac's pane frames, in its
/// window's proportions, and the tab's own pane.
@Suite struct TabSplitMapTests {
    /// a | (b over c), the left half 60%.
    let layout = WorkspaceLayout(screens: [WorkspaceLayout.Screen(id: 1, isActive: true, panes: [
        WorkspaceLayout.Pane(id: 1, tabIDs: ["a"]),
        WorkspaceLayout.Pane(id: 2, tabIDs: ["b"]),
        WorkspaceLayout.Pane(id: 3, tabIDs: ["c", "d"]),
    ], root: .split(id: 9, axis: .horizontal, ratio: 0.6, first: .pane(1),
                    second: .split(id: 10, axis: .vertical, ratio: 0.5, first: .pane(2), second: .pane(3))))])

    func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    @Test func framesAtTheMacsRatios() throws {
        let map = try #require(layout.splitMap(ofTab: "d"))
        #expect(map.pane == 3)
        #expect(map.cells.map(\.pane) == [1, 2, 3])
        #expect(close(map.cells[0].rect, CGRect(x: 0, y: 0, width: 0.6, height: 1)))
        #expect(close(map.cells[1].rect, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.5)))
        #expect(close(map.cells[2].rect, CGRect(x: 0.6, y: 0.5, width: 0.4, height: 0.5)))
        #expect(abs(map.aspect - 1.6) < 1e-6)
    }

    @Test func onePaneHasNoMap() {
        let single = WorkspaceLayout(screens: [WorkspaceLayout.Screen(id: 1, isActive: true, panes: [
            WorkspaceLayout.Pane(id: 1, tabIDs: ["a", "b"]),
        ], root: .pane(1))])
        #expect(single.splitMap(ofTab: "a") == nil)
    }

    @Test func zoomedPaneAndUnlistedTabHaveNoMap() {
        var zoomed = layout
        zoomed.screens[0].panes[1].isZoomed = true
        #expect(zoomed.splitMap(ofTab: "b") == nil)
        #expect(layout.splitMap(ofTab: "nope") == nil)
    }

    @Test func eachScreenMapsItsOwnSplits() throws {
        var two = layout
        two.screens.append(WorkspaceLayout.Screen(id: 2, isActive: false, panes: [
            WorkspaceLayout.Pane(id: 7, tabIDs: ["x"]),
            WorkspaceLayout.Pane(id: 8, tabIDs: ["y"]),
        ], root: .split(id: 11, axis: .vertical, ratio: 0.25, first: .pane(7), second: .pane(8))))
        let map = try #require(two.splitMap(ofTab: "y"))
        #expect(map.cells.map(\.pane) == [7, 8])
        #expect(close(map.cells[1].rect, CGRect(x: 0, y: 0.25, width: 1, height: 0.75)))
    }
}
