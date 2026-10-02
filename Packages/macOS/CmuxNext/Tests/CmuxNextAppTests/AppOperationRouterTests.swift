import CmuxNextApps
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// The App's operation sink for the prototype app engine.
@Suite struct AppOperationRouterTests {
    private func topology() -> ControlTopology {
        var topology = ControlTopology()
        let agentTab = ControlTabInfo(id: "tab_1", surface: "s1", kind: "terminal", title: "claude", name: "fix tests", terminalID: "term_1",
                                      agentState: "blocked")
        let plain = ControlTabInfo(id: "tab_2", surface: "s2", kind: "terminal", title: "zsh", terminalID: "term_2")
        let pane = ControlPaneInfo(id: "pane_1", handle: "p1", tabs: [agentTab, plain])
        topology.workspaces = [ControlWorkspaceInfo(id: "ws_1", handle: "w1", name: "cmux", unreadCount: 2,
                                                    screens: [ControlScreenInfo(id: "sc_1", handle: "sc1", panes: [pane])])]
        topology.focus = ControlFocus(workspaceID: "ws_1")
        return topology
    }

    @Test func agentListComesFromTabsWithAnAgentState() {
        let agents = AppTopologyReads.agents(topology()).arrayValue ?? []
        #expect(agents.count == 1)
        #expect(agents.first?["state"] == "blocked")
        #expect(agents.first?["terminal_id"] == "term_1")
        #expect(agents.first?["extra"]?["name"] == "fix tests")
    }

    @Test func terminalGetFindsTheTab() {
        #expect(AppTopologyReads.terminal(topology(), id: "term_2")?["tab_id"] == "tab_2")
        #expect(AppTopologyReads.terminal(topology(), id: "term_9") == nil)
    }

    @Test func workspaceAndTabListsReadTheMirror() {
        let workspaces = AppTopologyReads.workspaces(topology()).arrayValue ?? []
        #expect(workspaces.first?["unread"] == 2)
        #expect(workspaces.first?["focused"] == true)
        #expect(AppTopologyReads.tabs(topology(), workspace: "ws_1").arrayValue?.count == 2)
        #expect(AppTopologyReads.tabs(topology(), workspace: "ws_9").arrayValue?.isEmpty == true)
    }

    @Test func fingerprintsChangeOnlyForTheFamilyThatChanged() {
        var changed = topology()
        changed.workspaces[0].screens[0].panes[0].tabs[0].agentState = "working"
        let before = AppTopologyReads.fingerprints(topology())
        let after = AppTopologyReads.fingerprints(changed)
        #expect(before["agent.changed"] != after["agent.changed"])
        #expect(before["workspace.changed"] == after["workspace.changed"])
    }

    @Test func netFetchStripsCredentialsAndRefusesPlainHTTP() throws {
        let request = try AppNetFetch.request(["url": "https://api.github.com/x", "method": "post", "body": "{}",
                                               "headers": ["Authorization": "token x", "Cookie": "a=b", "Accept": "application/json"]])
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(throws: AppOperationError.self) { try AppNetFetch.request(["url": "http://api.github.com/x"]) }
    }

    @Test func storageRoundTripsPerAppAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-app-storage-\(UUID().uuidString)")
        let store = AppStorageStore(directory: directory)
        _ = try await store.set(app: "cmux/a", key: "k", value: ["x": 1])
        #expect(try await store.get(app: "cmux/a", key: "k") == ["x": 1])
        #expect(try await store.get(app: "cmux/b", key: "k") == .null)
        let reopened = AppStorageStore(directory: directory)
        #expect(try await reopened.keys(app: "cmux/a") == ["k"])
        await reopened.clear(app: "cmux/a")
        #expect(try await reopened.keys(app: "cmux/a") == [])
    }
}
