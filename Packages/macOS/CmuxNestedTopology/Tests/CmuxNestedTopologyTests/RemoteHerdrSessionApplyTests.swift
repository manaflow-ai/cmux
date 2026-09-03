import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrSessionApplyTests {
    private func leaf(_ paneID: String) -> RemoteHerdrLayoutNode {
        RemoteHerdrLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(paneID))
    }

    private func window(
        paneID: String,
        tabID: String,
        orderIndex: Int,
        title: String? = nil
    ) -> RemoteHerdrWindow {
        RemoteHerdrWindow(
            tabID: tabID,
            title: title ?? tabID,
            orderIndex: orderIndex,
            layout: leaf(paneID),
            activePaneID: paneID
        )
    }

    @Test func firstApplyCreatesInHerdrOrderThenClosesDefaults() {
        let windows = [
            window(paneID: "p-b", tabID: "t2", orderIndex: 2, title: "Two"),
            window(paneID: "p-a", tabID: "t1", orderIndex: 1, title: "One"),
        ]
        let session = RemoteHerdrSessionMirror.reconcile(windows: windows, previousTabIDs: [])
        let actions = RemoteHerdrSessionApply.actions(
            session,
            titles: ["t1": "One", "t2": "Two"],
            defaultsOpen: true,
            focusTabID: "t1"
        )
        #expect(actions.map(\.op) == ["create_tab", "create_tab", "close_default_tabs", "focus_tab"])
        #expect(actions[0].tabID == "t1")
        #expect(actions[1].tabID == "t2")
        #expect(actions[0].title == "One")
    }

    @Test func closeGoneTabsAfterCreate() {
        let windows = [window(paneID: "p-a", tabID: "t1", orderIndex: 0)]
        let session = RemoteHerdrSessionMirror.reconcile(
            windows: windows, previousTabIDs: ["t1", "t-gone"]
        )
        let actions = RemoteHerdrSessionApply.actions(session)
        #expect(actions.map(\.op) == ["close_tab"])
        #expect(actions[0].tabID == "t-gone")
    }

    @Test func reorderWhenOrderChanged() {
        let windows = [
            window(paneID: "p-a", tabID: "t1", orderIndex: 0),
            window(paneID: "p-b", tabID: "t2", orderIndex: 1),
        ]
        let session = RemoteHerdrSessionMirror.reconcile(
            windows: windows, previousTabIDs: ["t2", "t1"]
        )
        #expect(session.orderChanged)
        let actions = RemoteHerdrSessionApply.actions(session)
        #expect(actions.map(\.op) == ["reorder_tabs"])
        #expect(actions[0].orderedTabIDs == ["t1", "t2"])
    }

    @Test func noReorderForSingleTab() {
        let windows = [window(paneID: "p-a", tabID: "t1", orderIndex: 0)]
        let session = RemoteHerdrSessionMirror.reconcile(windows: windows, previousTabIDs: ["t1"])
        #expect(session.orderChanged == false)
        #expect(RemoteHerdrSessionApply.actions(session).isEmpty)
    }

    @Test func renameKeptTab() {
        let windows = [window(paneID: "p-a", tabID: "t1", orderIndex: 0, title: "Now")]
        let session = RemoteHerdrSessionMirror.reconcile(windows: windows, previousTabIDs: ["t1"])
        let actions = RemoteHerdrSessionApply.actions(
            session, titles: ["t1": "Now"], previousTitles: ["t1": "Was"]
        )
        #expect(actions.map(\.op) == ["rename_tab"])
        #expect(actions[0].title == "Now")
    }
}
