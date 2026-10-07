import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The Chief moves to a server: Home keeps ONE Chief tab, in the same pane,
/// now showing the placed chief's conversation; the tab that showed the local
/// Chief closes (the one-history migration carries its messages over).
@MainActor
@Suite struct HomeChiefMoveTests {
    private func store(_ tabs: [String]) throws -> DaemonStore {
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[
        {"active":true,"id":1,"key":"0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a01","name":"Home","kind":"home",
        "screens":[{"active":true,"id":3,"layout":{"pane":4,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":4,"name":null,
        "tabs":[\(tabs.joined(separator: ","))]}]}]}]}
        """
        let store = DaemonStore()
        store.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8)))
        return store
    }

    private func tab(_ surface: Int, _ conversation: String, owner: String) -> String {
        #"{"kind":"conversation","name":"","surface":\#(surface),"dead":false,"browser_renderer":"frontend","conversation":{"conversation":"\#(conversation)","owner":"\#(owner)"}}"#
    }

    @Test func theLocalChiefTabGivesWayToThePlacedChief() throws {
        let store = try store([tab(7, "conv_01LOCALCHIEF", owner: "local"), tab(8, "conv_01OTHER", owner: "local")])
        let move = HomeChiefSource.move(local: "conv_01LOCALCHIEF", chief: "conv_01CLOUDCHIEF", in: store.workspaces)
        #expect(move.close.map(\.rawValue) == [7], "only the local Chief tab closes; other conversations stay")
        #expect(move.pane != nil, "the placed chief opens where the local Chief was")
    }

    /// The local Chief with history stays the Chief: a tab that a placed
    /// chief opened in its place closes, and the local Chief tab is the one.
    @Test func thePlacedChiefTabGivesWayBackToTheLocalChiefWithHistory() throws {
        let store = try store([tab(7, "conv_01LOCALCHIEF", owner: "local"), tab(9, "conv_01CLOUDCHIEF", owner: "cloud")])
        let placed = CloudChief.parse(["id": "agent_A", "display_name": "Chief", "is_default": true, "rev": 2,
                                       "main_conversation": "conv_01CLOUDCHIEF",
                                       "brain_place": ["host": "host_aaaaaaaaaaaaaaaaaaaa", "install": "inst_aaaaaaaaaaaaaaaaaaaa"]])
        let chief = try #require(HomeChiefSource.choose(local: "conv_01LOCALCHIEF", localHasHistory: true, placed: placed))
        #expect(chief == "conv_01LOCALCHIEF")
        let stale = HomeChiefSource.staleChiefTabs(placed: placed?.mainConversation, chief: chief, in: store.workspaces)
        #expect(stale.map(\.rawValue) == [9], "the placed chief's tab closes; the local Chief tab stays")
        #expect(HomeChiefSource.staleChiefTabs(placed: "conv_01CLOUDCHIEF", chief: "conv_01CLOUDCHIEF", in: store.workspaces).isEmpty)
    }

    @Test func nothingMovesWhenTheChiefIsLocalOrAlreadyPlaced() throws {
        let store = try store([tab(7, "conv_01LOCALCHIEF", owner: "local")])
        #expect(HomeChiefSource.move(local: "conv_01LOCALCHIEF", chief: "conv_01LOCALCHIEF", in: store.workspaces).close.isEmpty)
        #expect(HomeChiefSource.move(local: nil, chief: "conv_01CLOUDCHIEF", in: store.workspaces).close.isEmpty)
        let moved = try self.store([tab(9, "conv_01CLOUDCHIEF", owner: "cloud")])
        #expect(HomeChiefSource.move(local: "conv_01LOCALCHIEF", chief: "conv_01CLOUDCHIEF", in: moved.workspaces).close.isEmpty)
    }
}
