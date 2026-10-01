import Foundation
import Testing
@testable import CmuxNextDaemon

/// Quit's End Sessions, Keep Layout (user decision 2026-09-30): the daemon
/// keeps each ended terminal's tab, dead (`end-terminals-keep-layout-v1`),
/// and the next launch restarts a shell in each kept tab, in the directory
/// the plan recorded, without touching the panes, splits or ratios.
@Suite struct KeptLayoutTests {
    static func tree(dead: Bool) throws -> DaemonTree {
        try JSONDecoder().decode(DaemonTree.self, from: Data(#"""
        {"workspace_revision":4,
         "workspaces":[{"id":1,"key":"k1","name":"api","active":true,
           "screens":[{"id":2,"active":true,"active_pane":3,"zoomed_pane":null,
             "layout":{"type":"split","dir":"right","ratio":0.3,"a":{"type":"leaf","pane":3},"b":{"type":"leaf","pane":6}},
             "panes":[
               {"id":3,"name":null,"active_tab":0,"tabs":[
                 {"surface":4,"tab_resource_id":"tab_a","kind":"pty","name":"server","title":"zsh","size":null,"dead":\#(dead),"pinned":true,"cwd":"/repo/api","git_branch":null,"git_detached":false},
                 {"surface":5,"tab_resource_id":"tab_b","kind":"browser","name":null,"title":"Docs","size":null,"dead":false,"pinned":false,"cwd":null,"git_branch":null,"git_detached":false}]},
               {"id":6,"name":null,"active_tab":0,"tabs":[
                 {"surface":7,"tab_resource_id":"tab_c","kind":"pty","name":null,"title":"zsh","size":null,"dead":\#(dead),"pinned":false,"cwd":"/repo","git_branch":null,"git_detached":false},
                 {"surface":8,"tab_resource_id":"tab_d","kind":"pty","name":null,"title":"zsh","size":null,"dead":\#(dead),"pinned":false,"cwd":"/tmp","git_branch":null,"git_detached":false}]}]}]}]}
        """#.utf8))
    }

    @Test func thePlanRecordsEveryLiveTerminalTabsDirectory() throws {
        let plan = KeptLayoutPlan(tree: try Self.tree(dead: false))
        #expect(plan.tabs == ["tab_a": .init(cwd: "/repo/api"), "tab_c": .init(cwd: "/repo"), "tab_d": .init(cwd: "/tmp")])
        let decoded = try JSONDecoder().decode(KeptLayoutPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }

    @Test func relaunchTargetsTheDeadTabsThePlanLists() throws {
        let plan = KeptLayoutPlan(tabs: ["tab_a": .init(cwd: "/repo/api"), "tab_d": .init(cwd: "/tmp")])
        let steps = KeptTabRelaunch.steps(tree: try Self.tree(dead: true), plan: plan)
        #expect(steps.map(\.deadSurface) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 8)])
        #expect(steps.map(\.pane) == [PaneID(rawValue: 3), PaneID(rawValue: 6)])
        #expect(steps.map(\.index) == [0, 1])
        #expect(steps.map(\.cwd) == ["/repo/api", "/tmp"])
        #expect(steps[0].name == "server" && steps[0].pinned)
        #expect(steps.allSatisfy { $0.workspace == WorkspaceKey(rawValue: "k1") })
    }

    @Test func liveTabsAndUnlistedTabsAreNeverRelaunched() throws {
        let plan = KeptLayoutPlan(tabs: ["tab_a": .init(cwd: nil), "tab_b": .init(cwd: nil)])
        #expect(KeptTabRelaunch.steps(tree: try Self.tree(dead: false), plan: plan).isEmpty)
        #expect(KeptTabRelaunch.steps(tree: try Self.tree(dead: true), plan: KeptLayoutPlan(tabs: [:])).isEmpty)
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

/// The daemon reports a tab's directory only from its launch or the
/// shell's OSC 7 report; a shell that changed directory without one would
/// restart in the wrong place. The app measures each shell's directory and
/// it overrides the tree's; a tab with neither restarts in `fallback`.
@Suite struct KeptLayoutDirectoryTests {
    @Test func measuredDirectoriesOverrideTheTreeAndTheFallbackFillsTheRest() throws {
        let plan = KeptLayoutPlan(tabs: ["tab_a": .init(cwd: "/repo/api"), "tab_c": .init(cwd: nil), "tab_d": .init(cwd: nil)])
        let filled = plan.withDirectories(["tab_a": "/tmp", "tab_c": "/repo"], fallback: "/Users/me")
        #expect(filled.tabs == ["tab_a": .init(cwd: "/tmp"), "tab_c": .init(cwd: "/repo"), "tab_d": .init(cwd: "/Users/me")])
    }
}
