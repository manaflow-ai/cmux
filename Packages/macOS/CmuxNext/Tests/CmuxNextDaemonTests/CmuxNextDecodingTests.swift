import Foundation
import Testing
@testable import CmuxNextDaemon

/// Decodes responses and events captured from the branch cmux-tui
/// (commit 4adc02cdae6, PR 15518) with the pinned hosted binary.
@Suite struct CmuxNextDecodingTests {
    @Test func treeCarriesGroupsTabGroupsAndTabMetadata() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces-cmux-next.json")
        #expect(tree.groups.map(\.id) == ["agents"])
        #expect(tree.groups.first?.color == "blue")
        let workspace = try #require(tree.workspaces.first)
        #expect(workspace.group == "agents")
        let pane = try #require(workspace.screens.first?.panes.first)
        let group = try #require(pane.tabGroups.first)
        #expect(group.id == "tg1")
        #expect(group.surfaces == [2, 5])
        #expect(group.start == 1)
        #expect(group.count == 2)
        #expect(group.savedID == "saved_bcb7f9e9dfee40e6a2772770440ad8e9")
        #expect(pane.tabs.filter { $0.tabGroup == "tg1" }.map(\.surface) == [2, 5])
        #expect(pane.tabs.first?.pinned == true)
        #expect(pane.tabs.first?.cwd == "/tmp")
    }

    @Test func tabGroupResultsInEveryShape() throws {
        let created = try Fixture.response(TabGroupResult.self, "create-tab-group.json")
        #expect(created.group?.name == "API")
        #expect(created.groupID == "tg1")
        #expect(created.surfaces == [2, 5])
        #expect(created.pane == 3)
        let ungrouped = try Fixture.response(TabGroupResult.self, "ungroup-tab-group.json")
        #expect(ungrouped.group == nil)
        #expect(ungrouped.groupID == "tg1")
        #expect(ungrouped.surfaces == [2, 5])
        let saved = try Fixture.response(SaveTabGroupRequest.Response.self, "save-tab-group.json")
        #expect(saved.saved == "saved_bcb7f9e9dfee40e6a2772770440ad8e9")
        let list = try Fixture.response(ListSavedTabGroupsRequest.Response.self, "list-saved-tab-groups.json")
        let record = try #require(list.savedGroups.first)
        #expect(record.tabs.count == 2)
        #expect(record.tabs.allSatisfy { $0.kind == .pty && $0.cwd == "/tmp" && $0.terminalID != nil })
        #expect(record.updatedAtMs == 1_790_674_592_332)
    }

    @Test func savedGroupsLinkToTheirLiveGroup() throws {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces-cmux-next.json")
        tree.savedTabGroups = try Fixture.response(ListSavedTabGroupsRequest.Response.self, "list-saved-tab-groups.json").savedGroups
        tree.linkSavedTabGroups()
        #expect(tree.savedTabGroups.first?.openGroup == "tg1")
    }

    @Test func dragPinAckAndGroupResults() throws {
        let pin = try Fixture.response(SetTabPinnedRequest.Response.self, "set-tab-pinned.json")
        #expect(pin == SetTabPinnedRequest.Response(surface: 6, pinned: true, index: 0, changed: true))
        let split = try Fixture.response(TabMoveResult.self, "move-tab-to-split.json")
        #expect(split.pane == 7)
        #expect(split.undoable)
        let ack = try Fixture.response(AckTabNotificationsRequest.Response.self, "ack-tab-notifications.json")
        #expect(!ack.cleared)
        let group = try Fixture.response(WorkspaceGroupResult.self, "create-workspace-group.json")
        #expect(group.group.id == "agents")
        let member = try Fixture.response(MoveWorkspaceToGroupRequest.Response.self, "move-workspace-to-group.json")
        #expect(member.group == "agents")
        let browser = try Fixture.response(NewFrontendBrowserTabRequest.Response.self, "new-frontend-browser-tab.json")
        #expect(browser.tabResourceID != nil)
    }

    @Test func tabChangedEventsEchoTransactions() throws {
        let events = try Fixture.lines("events-cmux-next.jsonl").map { DaemonEvent.decode(name: Fixture.eventName($0)!, line: $0) }
        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
        let echoed = events.compactMap(\.clientTransactionID)
        #expect(echoed.filter { $0 == "tx-group" }.count == 2)
        #expect(echoed.contains("tx-split"))
        #expect(events.contains { if case .workspaceMoved(let d) = $0 { d.entity.group == "agents" } else { false } })
    }
}
