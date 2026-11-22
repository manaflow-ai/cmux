import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The workspace-rows parity batch (verify/parity-mac.md: Resize Pane, Move Tab to New Dock
/// Column, Move Pane to New Workspace, Duplicate Screen) at the backend's boundary: the exact
/// lines the phone sends the Mac's daemon, against a mock Mac whose tree follows the moves.
@MainActor
@Suite struct WorkspaceRowsLiveTests {
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        private var moved = false
        private var screened = false
        func append(_ object: [String: Any]) { lock.withLock { lines.append(object) } }
        var mutations: [[String: Any]] {
            lock.withLock { lines }.filter { line in
                guard let cmd = line["cmd"] as? String else { return false }
                return !["list-workspaces", "subscribe", "set-client-info", "identify", "list-agents", "list-personal"].contains(cmd)
            }
        }
        var commands: [String] { mutations.compactMap { $0["cmd"] as? String } }
        func markMoved() { lock.withLock { moved = true } }
        func markScreen() { lock.withLock { screened = true } }

        /// wk1: screen 5 with pane 1 (s10 in /src/app, s11) left of pane 3 (s30, s40), split 7 at
        /// 60%. After Move Pane to New Workspace, wk2 holds pane 3's tabs. After Duplicate
        /// Screen, screen 6 (s70) is wk1's too.
        var tree: String {
            let (moved, screened) = lock.withLock { (self.moved, self.screened) }
            let paneThree = #"{"id":3,"name":"","active_tab":0,"tabs":[{"surface":30,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_c"},{"surface":40,"kind":"pty","title":"tests","dead":false,"terminal_id":"term_d"}]}"#
            let paneOne = #"{"id":1,"name":"","active_tab":0,"tabs":[{"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_a","cwd":"/src/app"},{"surface":11,"kind":"pty","title":"build","dead":false,"terminal_id":"term_b"}]}"#
            let layout = moved ? #"{"type":"leaf","pane":1}"# : #"{"type":"split","split":7,"dir":"right","ratio":0.6,"a":{"type":"leaf","pane":1},"b":{"type":"leaf","pane":3}}"#
            let panes = moved ? paneOne : paneOne + "," + paneThree
            var screens = #"{"id":5,"name":"Main","active":true,"active_pane":1,"zoomed_pane":null,"layout":\#(layout),"panes":[\#(panes)]}"#
            if screened {
                screens += #",{"id":6,"name":"","active":false,"active_pane":70,"zoomed_pane":null,"layout":{"type":"leaf","pane":70},"panes":[{"id":70,"name":"","active_tab":0,"tabs":[{"surface":70,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_s"}]}]}"#
            }
            var workspaces = #"{"id":1,"key":"wk1","name":"main","screens":[\#(screens)]}"#
            if moved {
                workspaces += #",{"id":2,"key":"wk2","name":"tests","screens":[{"id":8,"name":"","active":true,"active_pane":3,"zoomed_pane":null,"layout":{"type":"leaf","pane":3},"panes":[\#(paneThree)]}]}"#
            }
            return #"{"workspaces":[\#(workspaces)]}"#
        }

        func link() -> MockMacLink {
            MockMacLink { _, data in
                data.split(separator: 0x0A).compactMap { request -> Data? in
                    guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                          let id = object["id"] as? String else { return nil }
                    self.append(object)
                    let line: String
                    switch object["cmd"] as? String ?? "" {
                    case "list-workspaces":
                        line = #"{"id":"\#(id)","ok":true,"data":\#(self.tree)}"#
                    case "list-agents":
                        line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                    case "move-tab-to-new-workspace":
                        self.markMoved()
                        line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                    case "new-screen":
                        self.markScreen()
                        line = #"{"id":"\#(id)","ok":true,"data":{"surface":70}}"#
                    default:
                        line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                    }
                    return Data(line.utf8) + Data([0x0A])
                }
            }
        }
    }

    func connected(_ mac: Mac) async throws -> (LiveWorkspaceCreationBackend, Workspace) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await mac.link().openChannel(service: "daemon", args: [:]), macID: "m")
        let workspace = try #require(sync.tree?.workspaces.first { $0.id == "wk1" })
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller), workspace)
    }

    @Test func theScreensDividersReadWithThePanesOnEachSide() async throws {
        let (_, workspace) = try await connected(Mac())
        let screen = try #require(workspace.layout?.activeScreen)
        let split = try #require(screen.resizableSplits.first)
        #expect(screen.resizableSplits.count == 1)
        #expect(split.split == 7 && split.axis == .horizontal && split.first == [1] && split.second == [3])
        #expect(split.percent == 60)
        #expect(split.stepped(1) == 0.65)
        #expect(split.stepped(-1) == 0.55)
    }

    @Test func resizeSendsTheSplitsNewRatioAndNothingForAGoneDivider() async throws {
        let mac = Mac()
        let (backend, workspace) = try await connected(mac)
        try await backend.setSplitRatio(7, to: 0.65, in: workspace)
        await #expect(throws: WorkspaceCreationError.self) { try await backend.setSplitRatio(99, to: 0.5, in: workspace) }
        let line = try #require(mac.mutations.first)
        #expect(mac.commands == ["set-split-ratio"])
        #expect(line["split"] as? Int == 7 && line["ratio"] as? Double == 0.65 && line["transaction"] as? Int != nil)
    }

    @Test func moveTabToNewDockColumnPinsTheColumnToTheEdge() async throws {
        let mac = Mac()
        let (backend, workspace) = try await connected(mac)
        let tab = try #require(workspace.tabs.first { $0.id == "s40" })
        try await backend.moveTab(tab, toNewDock: .left, in: workspace)
        try await backend.moveTab(tab, toNewDock: .bottom, in: workspace)
        let lines = mac.mutations
        #expect(mac.commands == ["move-tab-to-column", "move-tab-to-column"])
        #expect(lines[0]["surface"] as? Int == 40 && lines[0]["pane"] as? Int == 3 && lines[0]["width"] as? Double == 0.5)
        #expect((lines[0]["dock"] as? [String: Any])?["edge"] as? String == "left")
        #expect((lines[0]["dock"] as? [String: Any])?["mode"] as? String == "docked")
        #expect((lines[1]["dock"] as? [String: Any])?["edge"] as? String == "bottom" && lines[1]["width"] as? Double == 0.3)
    }

    /// The first tab makes the workspace, the next follows into it by its daemon number.
    @Test func movePaneToNewWorkspaceMovesEveryTabInOrder() async throws {
        let mac = Mac()
        let (backend, workspace) = try await connected(mac)
        let created = try await backend.movePaneToNewWorkspace(3, in: workspace)
        #expect(created.id == "wk2")
        let lines = mac.mutations.filter { ($0["cmd"] as? String)?.hasPrefix("move-tab") == true }
        #expect(lines.map { $0["cmd"] as? String } == ["move-tab-to-new-workspace", "move-tab-to-workspace"])
        #expect(lines[0]["surface"] as? Int == 30)
        #expect(lines[1]["surface"] as? Int == 40 && lines[1]["workspace"] as? Int == 2)
    }

    @Test func theOnlyPaneIsNotMovedOut() async throws {
        let mac = Mac()
        let (backend, workspace) = try await connected(mac)
        _ = try await backend.movePaneToNewWorkspace(3, in: workspace)
        let after = try #require(backend.sync.tree?.workspaces.first { $0.id == "wk1" })
        let before = mac.commands.count
        await #expect(throws: WorkspaceCreationError.self) { _ = try await backend.movePaneToNewWorkspace(1, in: after) }
        #expect(mac.commands.count == before)
    }

    /// A new screen, its terminal changed to the shown tab's folder, then named as the original.
    @Test func duplicateScreenNamesTheCopyAndOpensItsFolder() async throws {
        let mac = Mac()
        let (backend, workspace) = try await connected(mac)
        let screen = try #require(workspace.screens.first)
        let tab = try await backend.duplicateScreen(screen, in: workspace)
        #expect(tab.id == "s70")
        let lines = mac.mutations
        #expect(mac.commands == ["new-screen", "send", "rename-screen"])
        #expect(lines[0]["workspace"] as? Int == 1 && Set(lines[0].keys) == ["id", "cmd", "workspace"])
        #expect(lines[1]["surface"] as? Int == 70 && lines[1]["text"] as? String == "cd '/src/app' && clear\n")
        #expect(lines[2]["screen"] as? Int == 6 && lines[2]["name"] as? String == "Main")
    }
}
