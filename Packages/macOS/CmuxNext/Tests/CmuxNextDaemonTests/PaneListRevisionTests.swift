@testable import CmuxNextDaemon
import Foundation
import Testing

/// `DaemonStore.paneListRevision` moves when a pane came, went or sits in another screen or workspace, and for
/// nothing else. A reader that keeps one value per pane of the session (the window record's remembered tabs,
/// `WindowRecordSaver`) reads every pane again only when it moved, so a move for a tab, a title or a workspace
/// applied again would cost that reader a walk of the session per daemon change.
@MainActor @Suite struct PaneListRevisionTests {
    /// One workspace: one screen with `panes` panes of `tabs` tabs each; handles unique per workspace.
    private func workspace(_ index: Int, panes: Int = 1, tabs: Int = 2, title: String = "t") -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index * 100 + 3)), key: nil, name: "w\(index)",
                          screens: [screen(index, panes: panes, tabs: tabs, title: title)])
    }

    private func screen(_ index: Int, panes: Int = 1, tabs: Int = 2, title: String = "t") -> ScreenSnapshot {
        let base = UInt64(index * 100)
        let list = (0..<panes).map { pane in
            PaneSnapshot(id: PaneID(rawValue: base + 50 + UInt64(pane)),
                         tabs: (0..<tabs).map { TabSnapshot(surface: SurfaceID(rawValue: base + UInt64(pane * 10 + $0)), title: "\(title) \($0)") })
        }
        let layout: LayoutNode = panes == 1 ? .leaf(list[0].id)
            : .split(id: SplitID(rawValue: base + 90), resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(list[0].id), b: .leaf(list[1].id))
        return ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: layout, panes: list)
    }

    private func session(_ count: Int = 12) -> DaemonTree { DaemonTree(workspaces: (0..<count).map { workspace($0) }) }

    @Test func aWorkspaceAppliedAgainWithOtherTitlesMovesNoPaneList() {
        let store = DaemonStore()
        store.apply(snapshot: session())
        let before = store.paneListRevision
        var next = session()
        next.workspaces[7] = workspace(7, title: "renamed")
        store.apply(snapshot: next)
        #expect(store.workspaces[7].screens.first?.panes.first?.tabs.first?.titleText == "renamed 0", "the snapshot did not apply")
        #expect(store.paneListRevision == before, "a workspace applied again with the same panes moved the pane list")
    }

    @Test func aTabThatComesOrGoesMovesNoPaneList() {
        let store = DaemonStore()
        store.apply(snapshot: session())
        let before = store.paneListRevision, tabs = store.tabListRevision
        var next = session()
        next.workspaces[3] = workspace(3, tabs: 3)
        store.apply(snapshot: next)
        #expect(store.workspaces[3].screens.first?.panes.first?.tabs.count == 3, "the snapshot did not apply")
        #expect(store.tabListRevision != tabs, "a new tab did not move the tab list")
        #expect(store.paneListRevision == before, "a new tab moved the pane list")
        store.apply(snapshot: session())
        #expect(store.paneListRevision == before, "a closed tab moved the pane list")
    }

    @Test func aPaneThatComesOrGoesMovesThePaneList() {
        let store = DaemonStore()
        store.apply(snapshot: session())
        let before = store.paneListRevision
        var next = session()
        next.workspaces[3] = workspace(3, panes: 2)
        store.apply(snapshot: next)
        let came = store.paneListRevision
        #expect(came != before, "a new pane did not move the pane list")
        store.apply(snapshot: session())
        #expect(store.paneListRevision != came, "a closed pane did not move the pane list")
    }

    /// The screen keeps its handle and the pane keeps its id and its handle: only the workspace differs.
    @Test func aScreenThatMovesToAnotherWorkspaceMovesThePaneList() {
        let store = DaemonStore()
        store.apply(snapshot: session())
        let before = store.paneListRevision
        var next = session()
        next.workspaces[4].screens.append(next.workspaces[3].screens[0])
        next.workspaces[3].screens = []
        store.apply(snapshot: next)
        #expect(store.workspaces[3].screens.isEmpty && store.workspaces[4].screens.count == 2, "the snapshot did not apply")
        #expect(store.paneListRevision != before, "a screen in another workspace did not move the pane list")
    }

    /// A first snapshot of a new connection indexes every record again: the same panes are no change.
    @Test func theSamePanesIndexedAgainInFullMoveNoPaneList() {
        let store = DaemonStore()
        store.apply(snapshot: session())
        let before = store.paneListRevision
        store.connectionEpoch += 1
        let indexed = store.index.indexedRecords
        store.apply(snapshot: session())
        #expect(store.index.indexedRecords != indexed, "the snapshot did not apply in full")
        #expect(store.paneListRevision == before, "the same panes indexed again moved the pane list")
    }
}
