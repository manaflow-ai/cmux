import CmuxMobileHost
import CmuxNextDaemon
@testable import CmuxNextMobileLink
import Foundation
import Testing

@Suite("mobile tree projection")
struct MobileTreeProjectionTests {
    static func tree() throws -> DaemonTree {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces-cmux-next", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: try #require(object?["data"]))
        return try JSONDecoder().decode(DaemonTree.self, from: data)
    }

    @Test func workspacesPanesAndTabsUseTheDaemonsPublicIDs() throws {
        let tree = try Self.tree()
        let projection = MobileTreeProjection(hostID: "h_mac1")
        let state = projection.state(tree)
        #expect(state.host == "h_mac1")
        let workspace = try #require(state.workspaces.first)
        #expect(workspace.id == "ws_abc80578cfad5ea82be750435458066f")
        #expect(workspace.order == 0)
        let pane = try #require(workspace.panes.first)
        #expect(pane.id == "pane_b7f856a3006ea4125256935b989f91f2")
        #expect(pane.tabs.map(\.id) == ["tab_57e65aa8804473ab94bf69f7f01a1678", "tab_ec9ce68af6c8a2c9a658e3ede0502adb",
                                        "tab_c4d56d2675fed18de155e3e204a29516"])
        #expect(pane.tabs.allSatisfy { $0.kind == .terminal && $0.terminal?.hasPrefix("term_") == true })
        // The bridge's scope check resolves a terminal through the same state.
        #expect(state.tab(showingTerminal: "term_4b79f4134c7c1bf326b4a5936dcb705f")?.id == "tab_ec9ce68af6c8a2c9a658e3ede0502adb")
    }

    @Test func opsResolvePublicIDsToDaemonHandles() throws {
        let tree = try Self.tree()
        let projection = MobileTreeProjection(hostID: "h_mac1")
        #expect(projection.workspaceKey("ws_abc80578cfad5ea82be750435458066f", in: tree)?.rawValue
            == "0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01")
        #expect(projection.surface(ofTab: "tab_ec9ce68af6c8a2c9a658e3ede0502adb", in: tree)?.rawValue == 2)
        #expect(projection.tab(showing: "term_c346421f6a0783777d843810a6ccddfa", in: tree)?.surface.rawValue == 5)
        #expect(projection.workspaceKey("ws_missing", in: tree) == nil)
        #expect(projection.tab(showing: "term_missing", in: tree) == nil)
    }

    @Test func colorsAndIconsAreLimitedToTheWireForms() {
        #expect(MobileTreeProjection.wireColor("blue") == "blue")
        #expect(MobileTreeProjection.wireColor("#1a2B3c") == "#1a2B3c")
        #expect(MobileTreeProjection.wireColor("#1a2B3cFF") == "#1a2B3c")
        #expect(MobileTreeProjection.wireColor("#12345") == nil)
        #expect(MobileTreeProjection.wireColor("Blue") == nil)
        #expect(MobileTreeProjection.wireIcon("hammer.fill") == "hammer.fill")
        #expect(MobileTreeProjection.wireIcon("🔥") == nil)
        #expect(MobileTreeProjection.wireIcon(nil) == nil)
    }

    @Test func placementIndexIsTheFinalPositionInThePersonalOrder() {
        let s = "sess1", other = "sess2"
        let app = WorkspaceGroupID(rawValue: "grp_app")
        func row(_ session: String, _ key: String, _ index: Int, _ group: WorkspaceGroupID? = nil) -> PersonalWorkspace {
            PersonalWorkspace(sessionID: session, workspaceKey: WorkspaceKey(rawValue: key), index: index, group: group)
        }
        // Personal order: a(app) x(other session, app) b(app) c d
        let personal = PersonalState(workspaces: [
            row(s, "a", 0, app), row(other, "x", 1, app), row(s, "b", 2, app), row(s, "c", 3), row(s, "d", 4),
        ])
        let projection = MobileTreeProjection(hostID: "h_mac1")
        func place(_ key: String, _ group: WorkspaceGroupID?, _ index: Int) -> Int? {
            projection.personalPlacementIndex(of: WorkspaceKey(rawValue: key), group: group, index: index, personal: personal, sessionID: s)
        }
        // d to the top of app: before a.
        #expect(place("d", app, 0) == 0)
        // d to the second slot of app (after a, before b; x is not this host's).
        #expect(place("d", app, 1) == 2)
        // d to the end of app: right after b.
        #expect(place("d", app, 9) == 3)
        // a down to the end of the ungrouped section: after d (rest is x b c d).
        #expect(place("a", nil, 2) == 4)
        // c to an empty group keeps its place.
        #expect(place("c", WorkspaceGroupID(rawValue: "grp_empty"), 0) == 3)
        #expect(place("zz", nil, 0) == nil)
    }

    @Test func sharedGroupsWithoutPersonalState() throws {
        var tree = try Self.tree()
        tree.groups = [WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "grp_one"), name: "One", index: 0)]
        tree.workspaces[0].group = WorkspaceGroupID(rawValue: "grp_one")
        tree.workspaces[0].icon = "star"
        let state = MobileTreeProjection(hostID: "h_mac1").state(tree)
        #expect(state.groups == [MobileWorkspaceGroup(id: "grp_one", name: "One", order: 0)])
        #expect(state.workspaces.first?.group?.name == "One")
        #expect(state.workspaces.first?.icon == "star")
    }
}
