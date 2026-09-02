import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrHostApplyTests {
    private func leaf(
        _ paneID: String,
        width: Int = 80,
        height: Int = 24,
        x: Int = 0,
        y: Int = 0
    ) -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(width: width, height: height, x: x, y: y, content: .pane(paneID))
    }

    private func horizontalSplit() -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(
            width: 200,
            height: 50,
            x: 0,
            y: 0,
            content: .horizontal([
                leaf("w2:p1", width: 100, height: 50, x: 0, y: 0),
                leaf("w2:p2", width: 99, height: 50, x: 101, y: 0),
            ])
        )
    }

    @Test func firstApplyCreatesPanelsBeforeRebuild() throws {
        let window = RemoteHerdrWindow(
            tabID: "w2:t1",
            title: "Build",
            orderIndex: 0,
            layout: horizontalSplit(),
            activePaneID: "w2:p2"
        )
        let (_, result) = RemoteHerdrWindowMirror.apply(window: window, previous: nil)
        let plan = try #require(RemoteHerdrImpose.plan(from: result, title: "Build"))
        let actions = RemoteHerdrHostApply.actions(result: result, plan: plan)
        #expect(actions.map(\.op).prefix(3) == ["create_panel", "create_panel", "rebuild_tree"])
        #expect(actions[0].paneID == "w2:p1")
        #expect(actions[1].paneID == "w2:p2")
        #expect(actions.last?.op == "focus")
        #expect(actions.last?.paneID == "w2:p2")
        #expect(actions.contains { $0.op == "impose_divider" })
    }

    @Test func heldSplitSkipsImpose() throws {
        let window = RemoteHerdrWindow(
            tabID: "w2:t1",
            title: "Build",
            orderIndex: 0,
            layout: horizontalSplit()
        )
        let (_, result) = RemoteHerdrWindowMirror.apply(window: window, previous: nil)
        let hold = RemoteHerdrImpose.beginDividerDrag(
            splitKey: "s", axis: .horizontal, assignedCells: 50
        )
        let plan = try #require(RemoteHerdrImpose.plan(from: result, hold: hold))
        let actions = RemoteHerdrHostApply.actions(result: result, plan: plan)
        #expect(actions.filter { $0.op == "impose_divider" }.isEmpty)
    }
}
