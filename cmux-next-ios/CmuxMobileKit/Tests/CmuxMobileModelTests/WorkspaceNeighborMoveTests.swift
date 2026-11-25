import Foundation
import Testing
@testable import CmuxMobileModel

/// Move Workspace Above… / Below… (the Mac's pick-a-target moves): which rows are offered and
/// the order once the workspace sits next to the one picked.
@Suite struct WorkspaceNeighborMoveTests {
    static func ws(_ id: String) -> Workspace {
        Workspace(id: id, macID: "mac", title: id.uppercased(), directory: "~", tabs: [], lastActivityAt: Date())
    }

    let order = ["a", "b", "c", "d"].map(Self.ws)

    @Test func targetsLeaveOutTheRowItAlreadySitsBeside() {
        // b is right above c and right below a.
        #expect(WorkspaceNeighborMove.above.targets(for: order[1], in: order).map(\.id) == ["a", "d"])
        #expect(WorkspaceNeighborMove.below.targets(for: order[1], in: order).map(\.id) == ["c", "d"])
        #expect(WorkspaceNeighborMove.above.targets(for: Self.ws("z"), in: order).isEmpty)
    }

    @Test func theWorkspaceLandsOnThePickedSide() {
        #expect(WorkspaceNeighborMove.above.reordered(order[3], next: order[1], in: order).map(\.id) == ["a", "d", "b", "c"])
        #expect(WorkspaceNeighborMove.below.reordered(order[0], next: order[2], in: order).map(\.id) == ["b", "c", "a", "d"])
        #expect(WorkspaceNeighborMove.below.reordered(order[0], next: order[3], in: order).map(\.id) == ["b", "c", "d", "a"])
    }

    @Test func theMacsTitles() {
        #expect(WorkspaceNeighborMove.allCases.map(\.title) == ["Move Workspace Above…", "Move Workspace Below…"])
    }
}
