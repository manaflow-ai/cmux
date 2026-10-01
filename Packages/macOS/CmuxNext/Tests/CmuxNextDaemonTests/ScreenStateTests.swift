import Foundation
import Testing
@testable import CmuxNextDaemon

/// Screen metadata and screen groups as the daemon's protocol/2 state
/// resources: `screen.list` / `screen_group.list` decoding, the overlay on
/// the raw tree and its deltas, and the `screen.update` params.
@MainActor @Suite struct ScreenStateTests {
    private static let first: ResourceID = "screen_108542859012b9e35b7a1b73a47ebe10"
    private static let second: ResourceID = "screen_42351ba87372bc02f96d71f8c707ef7e"

    /// `screen.list` and `screen_group.list` results for the fixture's
    /// workspace: screen 17 pinned, pink, with an icon; both in one group.
    private func state() throws -> ScreenStateSnapshot {
        let screens = #"""
        [{"id":"screen_108542859012b9e35b7a1b73a47ebe10","workspace_id":"ws_b287f9cec6d7f869da16b84b4b34a56f",
          "extra":{"screen_group_id":"sgrp_1"}},
         {"id":"screen_42351ba87372bc02f96d71f8c707ef7e","workspace_id":"ws_b287f9cec6d7f869da16b84b4b34a56f",
          "extra":{"pinned":true,"color":"pink","icon":"terminal","screen_group_id":"sgrp_1"}}]
        """#
        let groups = #"""
        [{"id":"sgrp_1","workspace_id":"ws_b287f9cec6d7f869da16b84b4b34a56f","name":"Build","color":"orange",
          "collapsed":true,"screen_ids":["screen_42351ba87372bc02f96d71f8c707ef7e","screen_108542859012b9e35b7a1b73a47ebe10"]}]
        """#
        return ScreenStateSnapshot(
            screens: try JSONDecoder().decode([ScreenStateSnapshot.Screen].self, from: Data(screens.utf8)),
            groups: try JSONDecoder().decode([ScreenStateSnapshot.Group].self, from: Data(groups.utf8)))
    }

    private func decoratedTree() throws -> DaemonTree {
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.screenState = try state()
        tree.screenState.decorate(&tree)
        return tree
    }

    @Test func rawScreenJSONCarriesNoScreenState() throws {
        let json = #"{"id":4,"layout":{"type":"leaf","pane":3},"color":"green","icon":"🚀","pinned":true,"group":"sgrp_1"}"#
        let screen = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json.utf8))
        #expect(screen.color == nil && screen.icon == nil && !screen.pinned && screen.group == nil)
    }

    @Test func stateDecoratesScreensAndBuildsGroupRuns() throws {
        let tree = try decoratedTree()
        let workspace = try #require(tree.workspaces.first)
        #expect(workspace.screens.map(\.id) == [5, 17])
        let pinned = try #require(workspace.screens.last)
        #expect(pinned.pinned && pinned.color == "pink" && pinned.icon == "terminal" && pinned.group == "sgrp_1")
        #expect(!workspace.screens[0].pinned && workspace.screens[0].color == nil)
        let run = try #require(workspace.screenGroups.first)
        #expect(run.id == "sgrp_1" && run.name == "Build" && run.color == "orange" && run.collapsed)
        #expect(run.start == 0 && run.count == 2 && run.screens == [5, 17], "members in workspace order")
        #expect(tree.workspaces[1].screenGroups.isEmpty)
    }

    @Test func screenWithoutStateIsPlain() throws {
        let screens = try JSONDecoder().decode([ScreenStateSnapshot.Screen].self,
                                               from: Data(#"[{"id":"screen_1","extra":{}},{"id":"screen_2"}]"#.utf8))
        #expect(screens.map(\.meta) == [ScreenStateSnapshot.Meta(), ScreenStateSnapshot.Meta()])
    }

    @Test func rawScreenDeltaKeepsTheStateOverlay() throws {
        let store = DaemonStore()
        store.apply(snapshot: try decoratedTree())
        let line = try screenLine("screen-renamed", screen: 17, patch: ["name": "logs"])
        #expect(store.apply(DaemonEvent.decode(name: "screen-renamed", line: line)) == .none)
        let screen = try #require(store.screen(17))
        #expect(screen.name == "logs")
        #expect(screen.pinned && screen.color == "pink" && screen.group == "sgrp_1", "a raw delta does not clear screen state")
    }

    @Test func closingAMemberRebuildsTheGroupRun() throws {
        let store = DaemonStore()
        store.apply(snapshot: try decoratedTree())
        let line = try screenLine("screen-closed", screen: 5, patch: [:])
        #expect(store.apply(DaemonEvent.decode(name: "screen-closed", line: line)) == .none)
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.screenGroups.map(\.screens) == [[17]])
        #expect(workspace.screenGroups.first?.start == 0)
    }

    @Test func screenUpdateSendsNullToClearAndOmitsUnchanged() throws {
        let params = DaemonConnection.screenUpdateParams(Self.second, pinned: true, color: .clear, icon: .unchanged)
        #expect(params["screen"] == .string(Self.second.rawValue))
        #expect(params["pinned"] == .bool(true))
        #expect(params["color"] == .null)
        #expect(params["icon"] == nil)
        let set = DaemonConnection.screenUpdateParams(Self.first, pinned: nil, color: .unchanged, icon: .set("🧪"))
        #expect(set["pinned"] == nil && set["color"] == nil && set["icon"] == .string("🧪"))
    }

    @Test func screenMutationEnvelopeIsProtocolTwo() throws {
        let envelope = ResourceRequestEnvelope(id: 7, operation: "screen.move",
                                               params: ["screen": .string(Self.first.rawValue), "index": .number(1)],
                                               idempotencyKey: "cmux-next-screen-1")
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: envelope.line()) else {
            Issue.record("not an object")
            return
        }
        #expect(object["protocol"] == .string("cmux.protocol/2"))
        #expect(object["operation"] == .string("screen.move"))
        #expect(object["idempotency_key"] == .string("cmux-next-screen-1"))
        guard case .object(let params) = object["params"] else {
            Issue.record("no params")
            return
        }
        #expect(params["screen"] == .string(Self.first.rawValue) && params["index"] == .number(1))
        #expect(params["session"] == .string("current"))
    }
}

/// A raw screen event line built from the fixture's screen entity with
/// `patch` applied, as the daemon writes it.
private func screenLine(_ name: String, screen: Int, patch: [String: Any]) throws -> Data {
    let root = try #require(try JSONSerialization.jsonObject(with: Fixture.data("list-workspaces.json")) as? [String: Any])
    let data = try #require(root["data"] as? [String: Any])
    let workspaces = try #require(data["workspaces"] as? [[String: Any]])
    let screens = try #require(workspaces[0]["screens"] as? [[String: Any]])
    var entity = try #require(screens.first { ($0["id"] as? Int) == screen })
    entity.merge(patch) { _, new in new }
    let event: [String: Any] = ["event": name, "workspace": 1, "screen": screen, "entity": entity]
    return try JSONSerialization.data(withJSONObject: event)
}
