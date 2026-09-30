import Foundation
import Testing
@testable import CmuxNextDaemon

/// Screen metadata and screen groups (`screen-metadata-v1`,
/// `screen-groups-v1`): wire decoding, request encoding, and store deltas.
@MainActor @Suite struct ScreenMetadataTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    private func loadedStore() throws -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        return store
    }

    @Test func screenJSONDecodesColorIconPinAndGroup() throws {
        let json = #"{"id":4,"name":"logs","layout":{"type":"leaf","pane":3},"color":"green","icon":"🚀","pinned":true,"group":"sgrp_1"}"#
        let screen = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json.utf8))
        #expect(screen.color == "green")
        #expect(screen.icon == "🚀")
        #expect(screen.pinned)
        #expect(screen.group == "sgrp_1")

        let bare = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(#"{"id":4,"layout":{"type":"leaf","pane":3}}"#.utf8))
        #expect(bare.color == nil && bare.icon == nil && !bare.pinned && bare.group == nil)
    }

    @Test func workspaceJSONDecodesScreenGroupRuns() throws {
        let json = #"""
        {"id":1,"name":"w","screens":[],"screen_groups":[
          {"id":"sgrp_1","name":"Build","color":"orange","collapsed":true,"saved_id":"ssaved_1","start":1,"count":2,"screens":[5,6]}
        ]}
        """#
        let workspace = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        let group = try #require(workspace.screenGroups.first)
        #expect(group.id == "sgrp_1")
        #expect(group.name == "Build")
        #expect(group.color == "orange")
        #expect(group.collapsed)
        #expect(group.savedID == "ssaved_1")
        #expect(group.start == 1)
        #expect(group.screens == [5, 6])
    }

    @Test func setScreenMetadataSendsNullToClearAndOmitsUnchanged() throws {
        let json = try object(SetScreenMetadataRequest(screen: 4, color: .clear, icon: .set("star")))
        #expect(json["cmd"] == .string("set-screen-metadata"))
        #expect(json["screen"] == .number(4))
        #expect(json["color"] == .null)
        #expect(json["icon"] == .string("star"))
        #expect(json.keys.contains("pinned") == false)
    }

    @Test func screenOrderAndGroupRequestsEncode() throws {
        let move = try object(MoveScreenRequest(screen: 4, index: 2, workspace: 9))
        #expect(move["cmd"] == .string("move-screen"))
        #expect(move["index"] == .number(2))
        #expect(move["workspace"] == .number(9))

        let pin = try object(SetScreenPinnedRequest(screen: 4, pinned: true))
        #expect(pin["cmd"] == .string("set-screen-pinned"))
        #expect(pin["pinned"] == .bool(true))

        let create = try object(CreateScreenGroupRequest(screens: [4, 5], name: "Build", color: "red"))
        #expect(create["cmd"] == .string("create-screen-group"))
        #expect(create["screens"] == .array([.number(4), .number(5)]))
        #expect(create["color"] == .string("red"))

        let update = try object(UpdateScreenGroupRequest(group: "sgrp_1", collapsed: true))
        #expect(update["cmd"] == .string("update-screen-group"))
        #expect(update["collapsed"] == .bool(true))
        #expect(update.keys.contains("name") == false)

        let moveGroup = try object(MoveScreenGroupRequest(group: "sgrp_1", index: 0))
        #expect(moveGroup["cmd"] == .string("move-screen-group"))
        #expect(moveGroup["index"] == .number(0))
    }

    @Test func newScreenWithSpecKeepsScreenNameApartFromTheTabName() throws {
        let json = try object(NewScreenWithSpecRequest(workspace: 3, spec: ScreenSpec(name: "Logs", color: "green", index: 1, group: "sgrp_1"),
                                                       options: SpawnOptions(cwd: "/tmp", name: "tail")))
        #expect(json["cmd"] == .string("new-screen"))
        #expect(json["workspace"] == .number(3))
        #expect(json["screen_name"] == .string("Logs"))
        #expect(json["name"] == .string("tail"))
        #expect(json["color"] == .string("green"))
        #expect(json["index"] == .number(1))
        #expect(json["group"] == .string("sgrp_1"))
        #expect(json["cwd"] == .string("/tmp"))
        let moved = try object(MoveScreenRequest(screen: 4, newWorkspace: true))
        #expect(moved["new_workspace"] == .bool(true))
        #expect(moved["index"] == nil)
    }

    @Test func screenChangedDeltaUpdatesMetadataAndReorders() throws {
        let store = try loadedStore()
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.screens.map(\.handle) == [5, 17])

        let line = try screenChangedLine(screen: 17, index: 0, patch: ["color": "pink", "icon": "terminal", "pinned": true])
        let event = DaemonEvent.decode(name: "screen-changed", line: line)
        #expect(store.apply(event) == .none)

        #expect(workspace.screens.map(\.handle) == [17, 5])
        let screen = try #require(store.screen(17))
        #expect(screen.color == "pink")
        #expect(screen.icon == "terminal")
        #expect(screen.pinned)
    }

    @Test func screenGroupsFollowTheWorkspaceSnapshot() throws {
        let store = DaemonStore()
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        tree.workspaces[0].screenGroups = [ScreenGroupSnapshot(id: "sgrp_1", name: "Build", color: "green", start: 0, screens: [5, 17])]
        tree.workspaces[0].screens[0].group = "sgrp_1"
        tree.workspaces[0].screens[1].group = "sgrp_1"
        store.apply(snapshot: tree)
        let workspace = try #require(store.workspaces.first)
        #expect(workspace.screenGroups.map(\.id) == ["sgrp_1"])
        #expect(workspace.screens.map(\.group) == ["sgrp_1", "sgrp_1"])

        tree.workspaces[0].screenGroups = []
        tree.workspaces[0].screens[0].group = nil
        tree.workspaces[0].screens[1].group = nil
        store.apply(snapshot: tree)
        #expect(workspace.screenGroups.isEmpty)
        #expect(workspace.screens.allSatisfy { $0.group == nil })
    }
}

/// A `screen-changed` line built from the fixture's screen entity with
/// `patch` applied, as the daemon writes it.
private func screenChangedLine(screen: Int, index: Int, patch: [String: Any]) throws -> Data {
    let root = try #require(try JSONSerialization.jsonObject(with: Fixture.data("list-workspaces.json")) as? [String: Any])
    let data = try #require(root["data"] as? [String: Any])
    let workspaces = try #require(data["workspaces"] as? [[String: Any]])
    let screens = try #require(workspaces[0]["screens"] as? [[String: Any]])
    var entity = try #require(screens.first { ($0["id"] as? Int) == screen })
    entity.merge(patch) { _, new in new }
    let event: [String: Any] = ["event": "screen-changed", "workspace": 1, "screen": screen, "index": index, "entity": entity]
    return try JSONSerialization.data(withJSONObject: event)
}
