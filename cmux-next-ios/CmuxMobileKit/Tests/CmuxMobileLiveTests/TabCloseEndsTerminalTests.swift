import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// V5-5 / T-TABS-08: closing a terminal tab on the phone ends its Mac session
/// at once. `close-surface` only detaches the terminal (the daemon reaps a
/// tab-less terminal after its grace period, so the Mac listed it `running`
/// 50 s after the close); the phone has no undo, so it ends the terminal with
/// `close-terminal` right after the tab closes, unless another tab still
/// shows that terminal.
@MainActor
@Suite struct TabCloseEndsTerminalTests {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ object: [String: Any]) { lock.withLock { items.append(object) } }
        var all: [[String: Any]] { lock.withLock { items } }
        var mutations: [[String: Any]] {
            all.filter { ["close-surface", "close-terminal", "close-tab-group"].contains($0["cmd"] as? String ?? "") }
        }
    }

    /// wk1: s10 (pty, term_a), s11 (pty, term_b), s12 (remote-terminal, term_r);
    /// wk2: s13 shows term_b too.
    nonisolated static let tree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
        {"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_a","terminal_incarnation":"inc_a"},
        {"surface":11,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_b"},
        {"surface":12,"kind":"remote-terminal","title":"ssh","dead":false,"terminal_id":"term_r"}]}]}]},
      {"id":2,"key":"wk2","name":"other","screens":[{"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
        {"surface":13,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_b"}]}]}]},
      {"id":3,"key":"wk3","name":"grouped","screens":[{"active":true,"active_pane":3,"panes":[{"id":3,"active_tab":0,
        "tab_groups":[{"id":"tgrp_9","name":"Jobs","color":"green","collapsed":false,"start":0,"count":2,"surfaces":[20,21]}],
        "tabs":[
        {"surface":20,"kind":"pty","title":"one","dead":false,"terminal_id":"term_c","group":"tgrp_9"},
        {"surface":21,"kind":"pty","title":"two","dead":false,"terminal_id":"term_d","group":"tgrp_9"},
        {"surface":22,"kind":"pty","title":"three","dead":false,"terminal_id":"term_d"}]}]}]}
    ]}
    """#

    nonisolated static func daemon(_ seen: Requests) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).map { request -> Data in
                let object = try! JSONSerialization.jsonObject(with: Data(request)) as! [String: Any]
                seen.append(object)
                let id = object["id"] as! String
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    // One line: the client splits replies on newlines.
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree.replacingOccurrences(of: "\n", with: ""))}"#
                case "process-info":
                    // s10 runs `sleep`, s13 an idle Codex, s20 `yes`; the rest sit at the shell.
                    let program = [10: "sleep", 13: "codex", 20: "/usr/bin/yes"][object["surface"] as? Int ?? 0] ?? "zsh"
                    line = #"{"id":"\#(id)","ok":true,"data":{"pid":1,"command":null,"foreground_executable":"\#(program)"}}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
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

    @Test func closingATerminalTabEndsItsTerminalOnTheMac() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s10", in: sync)
        try await backend.closeTab(tab, in: workspace)
        let mutations = seen.mutations
        #expect(mutations.map { $0["cmd"] as? String } == ["close-surface", "close-terminal"])
        #expect(mutations.first?["surface"] as? Int == 10)
        #expect(mutations.last?["terminal_id"] as? String == "term_a")
        #expect(mutations.last?["terminal_incarnation"] as? String == "inc_a")
    }

    @Test func aTerminalShownInAnotherTabKeepsRunning() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s11", in: sync)
        try await backend.closeTab(tab, in: workspace)
        #expect(seen.mutations.map { $0["cmd"] as? String } == ["close-surface"])
    }

    @Test func aRemoteTerminalIsOnlyDetached() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s12", in: sync)
        try await backend.closeTab(tab, in: workspace)
        #expect(seen.mutations.map { $0["cmd"] as? String } == ["close-surface"])
    }

    /// N2/A1: the close question reads the Mac's real foreground program
    /// (`process-info`), as the Mac's own close does.
    @Test func theRunningProgramsComeFromTheMac() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (sleeping, workspace) = try tab("s10", in: sync)
        let (idle, _) = try tab("s11", in: sync)
        #expect(await backend.runningPrograms(of: [sleeping, idle], in: workspace) == ["sleep"])
        let (codex, other) = try tab("s13", in: sync)
        #expect(await backend.runningPrograms(of: [codex], in: other) == ["codex"])
        #expect(seen.all.filter { $0["cmd"] as? String == "process-info" }.count == 3)
    }

    /// A2: Close Tab Group ends each member's terminal as a tab close does, but
    /// keeps one another tab still shows.
    @Test func closingATabGroupEndsItsTerminals() async throws {
        let seen = Requests()
        let (backend, sync) = try await connected(seen)
        let (tab, workspace) = try tab("s20", in: sync)
        #expect(tab.group?.id == "tgrp_9")
        try await backend.editTabGroup(.close, tab: tab, in: workspace)
        let mutations = seen.mutations
        #expect(mutations.map { $0["cmd"] as? String } == ["close-tab-group", "close-terminal"])
        #expect(mutations.last?["terminal_id"] as? String == "term_c")
    }
}
