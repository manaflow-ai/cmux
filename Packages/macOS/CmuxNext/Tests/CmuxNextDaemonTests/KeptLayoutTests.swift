import Foundation
import Testing
@testable import CmuxNextDaemon

/// Quit's End Sessions, Keep Layout (user decision 2026-09-30): the daemon's
/// workspace store keeps each ended terminal's tab, dead, with a
/// `relaunch: {cwd}` record (`end-terminals-keep-layout-v1`); the next
/// launch restarts a shell in each kept tab in that directory without
/// touching the panes, splits or ratios.
@Suite struct KeptLayoutTests {
    static let tree: DaemonTree = try! JSONDecoder().decode(DaemonTree.self, from: Data(#"""
    {"workspace_revision":4,
     "workspaces":[{"id":1,"key":"k1","name":"api","active":true,
       "screens":[{"id":2,"active":true,"active_pane":3,"zoomed_pane":null,
         "layout":{"type":"split","dir":"right","ratio":0.3,"a":{"type":"leaf","pane":3},"b":{"type":"leaf","pane":6}},
         "panes":[
           {"id":3,"name":null,"active_tab":0,"tabs":[
             {"surface":4,"tab_resource_id":"tab_a","kind":"pty","name":"server","title":"","dead":true,"pinned":true,"relaunch":{"cwd":"/repo/api"}},
             {"surface":5,"tab_resource_id":"tab_b","kind":"browser","title":"Docs","dead":false,"pinned":false}]},
           {"id":6,"name":null,"active_tab":0,"tabs":[
             {"surface":7,"tab_resource_id":"tab_c","kind":"pty","title":"zsh","dead":false,"pinned":false,"cwd":"/repo"},
             {"surface":8,"tab_resource_id":"tab_d","kind":"pty","title":"","dead":true,"pinned":false,"relaunch":{"cwd":null}},
             {"surface":9,"tab_resource_id":"tab_e","kind":"pty","title":"","dead":true,"pinned":false}]}]}]}]}
    """#.utf8))

    @Test func theRelaunchRecordDecodes() {
        let tabs = Self.tree.workspaces[0].screens[0].panes.flatMap(\.tabs)
        #expect(tabs.map(\.relaunch) == [TabRelaunch(cwd: "/repo/api"), nil, nil, TabRelaunch(cwd: nil), nil])
    }

    @Test func relaunchTargetsTheKeptTabsOnly() {
        let steps = KeptTabRelaunch.steps(tree: Self.tree, fallbackCwd: "/Users/me")
        #expect(steps.map(\.deadSurface) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 8)])
        #expect(steps.map(\.pane) == [PaneID(rawValue: 3), PaneID(rawValue: 6)])
        #expect(steps.map(\.index) == [0, 1])
        #expect(steps.map(\.cwd) == ["/repo/api", "/Users/me"], "a kept tab with no directory restarts in the fallback")
        #expect(steps[0].name == "server" && steps[0].pinned)
        #expect(steps.allSatisfy { $0.workspace == WorkspaceKey(rawValue: "k1") })
    }

    @Test func keepLayoutIsSentOnlyWhenAsked() throws {
        let encode = { (request: ShutdownDaemonRequest) throws -> [String: JSONValue] in
            let data = try WireCoding.encodeRequest(request, id: 1)
            guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
            return object
        }
        let kept = try encode(ShutdownDaemonRequest(pid: 1, generation: DaemonGeneration(rawValue: "g"), endTerminals: true, keepLayout: true))
        #expect(kept["keep_layout"] == .bool(true) && kept["end_terminals"] == .bool(true))
        let plain = try encode(ShutdownDaemonRequest(pid: 1, generation: DaemonGeneration(rawValue: "g"), endTerminals: true))
        #expect(plain["keep_layout"] == nil)
    }
}
