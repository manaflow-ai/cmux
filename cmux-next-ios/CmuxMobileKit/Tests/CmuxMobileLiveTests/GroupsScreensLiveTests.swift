import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Tab group appearance and moves, New Tab in Group, and screens (verify/parity-mac.md): the
/// tree the phone reads (screens, group icon and collapse, pane slots, chat docks) and the exact
/// daemon lines it sends, against a mock Mac that lists a new tab once it made one.
@MainActor
@Suite struct GroupsScreensLiveTests {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        private var made = false
        func append(_ object: [String: Any]) {
            lock.withLock {
                items.append(object)
                if ["new-tab", "new-screen"].contains(object["cmd"] as? String ?? "") { made = true }
            }
        }
        var created: Bool { lock.withLock { made } }
        /// The requests that change the Mac (the reads the sync makes on its own are left out).
        static let changes: Set<String> = ["update-tab-group", "move-tab-group", "move-tab-group-to-split", "move-tab-group-to-column",
                                           "move-tab-group-to-new-workspace", "new-tab", "add-tabs-to-tab-group", "focus-pane",
                                           "select-screen", "new-screen", "rename-screen", "close-screen"]
        var mutations: [[String: Any]] {
            lock.withLock { items }.filter { Self.changes.contains($0["cmd"] as? String ?? "") }
        }
    }

    /// wk1: screen 10 (active; pane 1 with a pinned tab, group tg_a (two tabs, icon, green), a
    /// tab, group tg_b (collapsed); pane 2 in a chat dock with group tg_c) and screen 11 "logs"
    /// (pane 3). wk2: screen 12 whose active pane 6 is its chat dock, pane 4 beside it.
    /// wk3: one screen. After a new tab or screen, s99 shows in wk1's screen 14.
    nonisolated static func tree(created: Bool) -> String {
        let extra = created
            ? #",{"id":14,"name":"","active":false,"active_pane":7,"panes":[{"id":7,"active_tab":0,"tabs":[{"surface":99,"kind":"pty","title":"zsh","dead":false}]}]}"#
            : ""
        return #"""
        {"workspaces":[
          {"id":1,"key":"wk1","name":"main","screens":[
            {"id":10,"name":"","active":true,"active_pane":1,
             "columns":[{"layout":{"type":"leaf","pane":1}},{"layout":{"type":"leaf","pane":2},"dock":{"edge":"right","mode":"docked","role":"agent_chat"}}],
             "panes":[
              {"id":1,"active_tab":1,"tab_groups":[
                 {"id":"tg_a","name":"Jobs","color":"green","collapsed":false,"icon":"hammer","surfaces":[20,21]},
                 {"id":"tg_b","name":"","color":"red","collapsed":true,"icon":null,"surfaces":[23]}],
               "tabs":[
                {"surface":19,"kind":"pty","title":"pinned","dead":false,"pinned":true},
                {"surface":20,"kind":"pty","title":"one","dead":false,"group":"tg_a"},
                {"surface":21,"kind":"pty","title":"two","dead":false,"group":"tg_a"},
                {"surface":22,"kind":"pty","title":"three","dead":false},
                {"surface":23,"kind":"pty","title":"four","dead":false,"group":"tg_b"}]},
              {"id":2,"active_tab":0,"tab_groups":[{"id":"tg_c","name":"Dock","color":"blue","collapsed":false,"surfaces":[24]}],
               "tabs":[{"surface":24,"kind":"pty","title":"docked","dead":false,"group":"tg_c"}]}]},
            {"id":11,"name":"logs","active":false,"active_pane":3,"panes":[{"id":3,"active_tab":0,"tabs":[
                {"surface":30,"kind":"pty","title":"tail","dead":false}]}]}\#(extra)]},
          {"id":2,"key":"wk2","name":"other","screens":[
            {"id":12,"active":true,"active_pane":6,
             "columns":[{"layout":{"type":"leaf","pane":4}},{"layout":{"type":"leaf","pane":6},"dock":{"edge":"right","mode":"docked","role":"agent_chat"}}],
             "panes":[{"id":4,"active_tab":0,"tabs":[{"surface":40,"kind":"pty","title":"x","dead":false}]},
                      {"id":6,"active_tab":0,"tabs":[{"surface":60,"kind":"pty","title":"y","dead":false}]}]}]},
          {"id":3,"key":"wk3","name":"single","screens":[{"id":13,"active":true,"active_pane":5,"panes":[{"id":5,"active_tab":0,"tabs":[
            {"surface":50,"kind":"pty","title":"z","dead":false}]}]}]}
        ]}
        """#
    }

    nonisolated static func daemon(_ seen: Requests) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).map { request -> Data in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(request))) as? [String: Any],
                      let id = object["id"] as? String else { return Data() }
                seen.append(object)
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree(created: seen.created).replacingOccurrences(of: "\n", with: ""))}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "new-tab", "new-screen":
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":99}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }

    func connected(_ seen: Requests) async throws -> (LiveWorkspaceCreationBackend, WorkspaceSync) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await Self.daemon(seen).openChannel(service: "daemon", args: [:]), macID: "m")
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller), sync)
    }

    func tab(_ id: String, in sync: WorkspaceSync) throws -> (WorkspaceTab, Workspace) {
        let workspace = try #require(sync.tree?.workspaces.first { ws in ws.tabs.contains { $0.id == id } })
        return (try #require(workspace.tabs.first { $0.id == id }), workspace)
    }

    @Test func theTreeCarriesScreensGroupLooksSlotsAndChatDocks() async throws {
        let seen = Requests()
        let (_, sync) = try await connected(seen)
        let tree = try #require(sync.tree)
        let main = try #require(tree.workspaces.first { $0.id == "wk1" })
        #expect(main.screens.map(\.id) == [10, 11])
        #expect(main.screens.map(\.isActive) == [true, false])
        #expect(main.screens[1].title(at: 1) == "logs" && main.screens[0].title(at: 0) == "Screen 1")
        #expect(main.screens[0].tabIDs == ["s19", "s20", "s21", "s22", "s23", "s24"])
        #expect(main.screens[1].activePane == 3 && main.screens[0].panes == [1, 2])
        #expect(main.screenLabel(ofTab: "s30") == "logs")
        let (one, _) = try tab("s20", in: sync)
        #expect(one.group?.icon == "hammer" && one.group?.isCollapsed == false)
        let (four, _) = try tab("s23", in: sync)
        #expect(four.group?.icon == nil && four.group?.isCollapsed == true)
        #expect(tree.paneSlots[1]?.map(\.group) == [nil, "tg_a", "tg_a", nil, "tg_b"])
        #expect(tree.paneSlots[1]?.first?.pinned == true)
        #expect(tree.chatDockPanes == [2, 6])
        #expect(tree.workspaces.first { $0.id == "wk3" }?.screenLabel(ofTab: "s50") == nil)
    }

    /// The Mac's `TabGroupReorder.targetIndex`, read against the pane's slots.
    @Test func groupMoveIndexMatchesTheMac() {
        typealias Slot = DaemonTree.PaneSlot
        let slots = [Slot(group: nil, pinned: true), Slot(group: "a", pinned: false), Slot(group: "a", pinned: false),
                     Slot(group: nil, pinned: false), Slot(group: "b", pinned: false), Slot(group: "b", pinned: false)]
        #expect(DaemonTree.tabGroupMoveIndex(of: "a", forward: false, in: slots) == nil)  // a pinned tab is never crossed
        #expect(DaemonTree.tabGroupMoveIndex(of: "a", forward: true, in: slots) == 2)
        #expect(DaemonTree.tabGroupMoveIndex(of: "b", forward: true, in: slots) == nil)  // the edge
        #expect(DaemonTree.tabGroupMoveIndex(of: "b", forward: false, in: slots) == 3)
        let groups = [Slot(group: "a", pinned: false), Slot(group: "b", pinned: false), Slot(group: "b", pinned: false)]
        #expect(DaemonTree.tabGroupMoveIndex(of: "a", forward: true, in: groups) == 2)  // past the whole next group
        #expect(DaemonTree.tabGroupMoveIndex(of: "b", forward: false, in: groups) == 0)
        #expect(DaemonTree.tabGroupMoveIndex(of: "x", forward: true, in: groups) == nil)
    }

    @Test func appearanceLines() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s20", in: sync)
        try await backend.editTabGroup(.setColor("purple"), tab: tab, in: workspace)
        try await backend.editTabGroup(.setIcon("🚀"), tab: tab, in: workspace)
        try await backend.editTabGroup(.setIcon(nil), tab: tab, in: workspace)
        try await backend.editTabGroup(.setCollapsed(true), tab: tab, in: workspace)
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == Array(repeating: "update-tab-group", count: 4))
        #expect(lines.allSatisfy { $0["group"] as? String == "tg_a" })
        #expect(lines[0]["color"] as? String == "purple" && lines[0].count == 4)  // id, cmd, group, color
        #expect(lines[1]["icon"] as? String == "🚀")
        #expect(lines[2]["icon"] is NSNull)  // null removes the icon
        #expect(lines[3]["collapsed"] as? Bool == true && lines[3]["name"] == nil)
    }

    @Test func moveLines() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (a, workspace) = try tab("s20", in: sync)
        let (b, _) = try tab("s23", in: sync)
        #expect(!backend.canMoveTabGroup(of: a, forward: false, in: workspace))
        #expect(backend.canMoveTabGroup(of: a, forward: true, in: workspace))
        await #expect(throws: WorkspaceCreationError.self) { try await backend.editTabGroup(.moveLeft, tab: a, in: workspace) }
        try await backend.editTabGroup(.moveRight, tab: a, in: workspace)
        try await backend.editTabGroup(.moveLeft, tab: b, in: workspace)
        try await backend.editTabGroup(.moveToSplit(.up), tab: a, in: workspace)
        try await backend.editTabGroup(.moveToColumn, tab: a, in: workspace)
        try await backend.editTabGroup(.moveToNewWorkspace, tab: a, in: workspace)
        // Into wk2: its shown pane 6 is its chat dock, so the pane beside it, at its end.
        try await backend.editTabGroup(.moveToWorkspace("wk2"), tab: a, in: workspace)
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == ["move-tab-group", "move-tab-group", "move-tab-group-to-split",
                                                      "move-tab-group-to-column", "move-tab-group-to-new-workspace", "move-tab-group"])
        #expect(lines[0]["index"] as? Int == 2 && lines[0]["pane"] as? Int == 1 && lines[0]["group"] as? String == "tg_a")
        #expect(lines[1]["index"] as? Int == 3 && lines[1]["group"] as? String == "tg_b")
        #expect(lines[2]["edge"] as? String == "top" && lines[2]["pane"] as? Int == 1)
        #expect(lines[3]["pane"] as? Int == 1)
        #expect(lines[4]["group"] as? String == "tg_a" && lines[4].count == 3)
        #expect(lines[5]["pane"] as? Int == 4 && lines[5]["index"] as? Int == 1)
        // The chat dock never splits: refused on the phone, nothing sent.
        let (docked, _) = try tab("s24", in: sync)
        await #expect(throws: WorkspaceCreationError.self) { try await backend.editTabGroup(.moveToSplit(.right), tab: docked, in: workspace) }
        #expect(seen.mutations.count == 6)
    }

    @Test func newTabInGroupMakesATerminalThenAddsIt() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (a, workspace) = try tab("s21", in: sync)
        let made = try await backend.newTabInGroup(of: a, in: workspace)
        #expect(made.id == "s99")
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == ["new-tab", "add-tabs-to-tab-group"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0].count == 3)  // no folder or program from the phone
        #expect(lines[1]["group"] as? String == "tg_a" && lines[1]["surfaces"] as? [Int] == [99])
    }

    @Test func screenLines() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let main = try #require(sync.tree?.workspaces.first { $0.id == "wk1" })
        try await backend.selectScreen(main.screens[1], in: main)
        try await backend.renameScreen(main.screens[1], in: main, to: "build")
        let made = try await backend.newScreen(in: main)
        #expect(made.id == "s99")
        try await backend.closeScreen(main.screens[1], in: main)
        let lines = seen.mutations
        #expect(lines.map { $0["cmd"] as? String } == ["focus-pane", "rename-screen", "new-screen", "close-screen"])
        // `select-screen` names no workspace; the screen's own active pane does.
        #expect(lines[0]["pane"] as? Int == 3)
        #expect(lines[1]["screen"] as? Int == 11 && lines[1]["name"] as? String == "build")
        #expect(lines[2]["workspace"] as? Int == 1 && lines[2].count == 3)
        #expect(lines[3]["screen"] as? Int == 11 && lines[3]["end_terminals"] as? Bool == true)
        // A workspace's only screen is never closed from the phone.
        let single = try #require(sync.tree?.workspaces.first { $0.id == "wk3" })
        await #expect(throws: WorkspaceCreationError.self) { try await backend.closeScreen(single.screens[0], in: single) }
        #expect(seen.mutations.count == 4)
    }
}
