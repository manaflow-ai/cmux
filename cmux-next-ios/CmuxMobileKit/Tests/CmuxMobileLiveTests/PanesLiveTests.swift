import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The Panes rows of the parity matrix (cmux#25834 slice A, and slice C's fork destinations) at
/// the backend's boundary: the pane layout the phone reads from the Mac's tree, and the exact
/// lines it sends the Mac's daemon for each pane action.
@MainActor
@Suite struct PanesLiveTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func append(_ object: [String: Any]) { lock.withLock { lines.append(object) } }
        /// The daemon's mutations, in order (reads left out).
        var mutations: [[String: Any]] {
            lock.withLock { lines }.filter { line in
                guard let cmd = line["cmd"] as? String else { return false }
                return !["list-workspaces", "subscribe", "set-client-info", "identify", "list-agents", "list-personal"].contains(cmd)
            }
        }
        var commands: [String] { mutations.compactMap { $0["cmd"] as? String } }
    }

    /// wk1, one screen: pane 1 (left, 70%) holds s10, s11 and the chat s12 (and its fork s41);
    /// right of it pane 2 (s20) above pane 3 (s30, s40, the new pane's terminal).
    nonisolated static let tree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"id":5,"name":"","active":true,"active_pane":1,"zoomed_pane":null,
        "layout":{"type":"split","split":7,"dir":"right","ratio":0.7,"a":{"type":"leaf","pane":1},
                  "b":{"type":"split","split":8,"dir":"down","ratio":0.5,"a":{"type":"leaf","pane":2},"b":{"type":"leaf","pane":3}}},
        "panes":[
        {"id":1,"name":null,"active_tab":1,"tabs":[
          {"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_a"},
          {"surface":11,"kind":"pty","title":"build","dead":false,"terminal_id":"term_b"},
          {"surface":12,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-a","harness":"claude"}}},
          {"surface":41,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-f","harness":"claude"}}}]},
        {"id":2,"name":"logs","active_tab":0,"tabs":[{"surface":20,"kind":"pty","title":"tail","dead":false,"terminal_id":"term_l"}]},
        {"id":3,"name":"","active_tab":0,"tabs":[
          {"surface":30,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_c"},
          {"surface":40,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_d"}]}]}]}
    ]}
    """#

    nonisolated static func daemon(_ seen: Seen) -> MockMacLink {
        MockMacLink { _, data in
            data.split(separator: 0x0A).compactMap { request -> Data? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(request)) as? [String: Any],
                      let id = object["id"] as? String else { return nil }
                seen.append(object)
                let line: String
                switch object["cmd"] as? String ?? "" {
                case "list-workspaces":
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree.replacingOccurrences(of: "\n", with: ""))}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "split", "new-pane", "new-pane-right":
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":40}}"#
                case "new-conversation-tab":
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":41}}"#
                case "undo-layout" where object["confirm_close"] as? Bool == true:
                    line = #"{"id":"\#(id)","ok":true,"data":{"undone":true,"screen":5,"revision":9}}"#
                case "undo-layout":
                    line = #"{"id":"\#(id)","ok":true,"data":{"undone":false,"confirmation_required":true,"screen":5,"revision":8,"closes_panes":[3]}}"#
                default:
                    line = #"{"id":"\#(id)","ok":true,"data":{}}"#
                }
                return Data(line.utf8) + Data([0x0A])
            }
        }
    }

    /// acpmux: `session/fork` of `sess-a` gives `sess-f`.
    nonisolated static func acpmux() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[]}"#)]
            case "session/fork": return [reply(#"{"sessionId":"sess-f"}"#)]
            default: return [reply("{}")]
            }
        }
    }

    /// The backend holds its acpmux hub weakly (the Mac session owns it): the suite keeps it.
    final class Hold: @unchecked Sendable { var hub: AcpmuxHub? }
    let hold = Hold()

    func connected(_ seen: Seen) async throws -> (LiveWorkspaceCreationBackend, Workspace) {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        await sync.bind(try await Self.daemon(seen).openChannel(service: "daemon", args: [:]), macID: "m")
        let hub = AcpmuxHub()
        await hub.bind(try await Self.acpmux().openChannel(service: "acpmux", args: [:]))
        hold.hub = hub
        let workspace = try #require(sync.tree?.workspaces.first { $0.id == "wk1" })
        return (LiveWorkspaceCreationBackend(sync: sync, link: controller, acpmux: hub), workspace)
    }

    // MARK: The layout read from the tree

    @Test func theTreeGivesThePanesTheirTabsAndTheSplits() async throws {
        let (_, workspace) = try await connected(Seen())
        let layout = try #require(workspace.layout)
        #expect(layout.screens.map(\.id) == [5])
        #expect(layout.panes.map(\.id) == [1, 2, 3])
        #expect(layout.pane(1)?.tabIDs == ["s10", "s11", "s12", "s41"])
        #expect(layout.pane(1)?.activeTabID == "s11")
        #expect(layout.pane(1)?.isFocused == true)
        #expect(layout.pane(2)?.isFocused == false)
        #expect(layout.pane(holding: "s30")?.id == 3)
        // A named pane shows its name; an unnamed one its place, as Focus Pane 1…9 counts.
        #expect(layout.panes.map(layout.title(of:)) == ["Pane 1", "logs", "Pane 3"])
        // Swap Pane offers only the sides with a neighbor.
        #expect(layout.swapDirections(of: 1) == [.right])
        #expect(layout.swapDirections(of: 2) == [.left, .down])
        #expect(layout.swapDirections(of: 3) == [.left, .up])
        #expect(layout.otherPanes(than: 2).map(\.id) == [1, 3])
        // Equalize Splits: the 70% split becomes 50% (one cell each side); the 50% one is equal.
        let screen = try #require(layout.activeScreen)
        #expect(screen.hasSplits)
        #expect(screen.unequalSplits.map(\.split) == [7])
        #expect(screen.unequalSplits.first?.equalized == 0.5)
    }

    @Test func equalizedRatiosFollowTheChainLikeTheMacs() {
        // Three side by side: right(a, right(b, c)) gives the outer split 1/3, the inner 1/2.
        let node = WorkspaceLayout.Node.split(id: 1, axis: .horizontal, ratio: 0.5, first: .pane(1),
                                              second: .split(id: 2, axis: .horizontal, ratio: 0.5, first: .pane(2), second: .pane(3)))
        let ratios = node.equalizedRatios
        #expect(ratios.map(\.split) == [1, 2])
        #expect(abs(ratios[0].equalized - 1.0 / 3.0) < 0.0001)
        #expect(ratios[1].equalized == 0.5)
        #expect(ratios[1].isEqual)
    }

    @Test func columnsAndStacksReadFromTheScreen() {
        let screen: [String: Any] = [
            "columns": [
                ["id": 1, "width": 0.5, "layout": ["type": "split", "split": 3, "dir": "down", "ratio": 0.8,
                                                    "a": ["type": "leaf", "pane": 1], "b": ["type": "leaf", "pane": 2]]],
                ["id": 2, "width": 0.5, "layout": ["type": "leaf", "pane": 4],
                 "rows": [["id": 9, "height": 1.0, "layout": ["type": "leaf", "pane": 4]]]],
            ],
        ]
        let trees = DaemonTree.equalizable(screen)
        #expect(trees.flatMap(\.equalizedRatios).map(\.split) == [3])
        #expect(DaemonTree.node(["type": "stack", "panes": [4, 5], "expanded": 5]) == .stack([4, 5], expanded: 5))
    }

    // MARK: The lines each action sends

    @Test func splitRightDownAndLeft() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let tab = try await backend.split(1, .right, in: workspace)
        #expect(tab.id == "s40")
        _ = try await backend.split(2, .down, in: workspace)
        // Split Left: the daemon's split right, then the two panes swap.
        _ = try await backend.split(1, .left, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["split", "split", "split", "swap-pane"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0]["dir"] as? String == "right")
        #expect(lines[1]["pane"] as? Int == 2 && lines[1]["dir"] as? String == "down")
        #expect(lines[2]["dir"] as? String == "right")
        #expect(lines[3]["pane"] as? Int == 1 && lines[3]["target"] as? Int == 3)
        // Only the lane's creation fields: no program, folder or environment.
        #expect(lines.prefix(3).allSatisfy { Set($0.keys).subtracting(["id", "cmd"]).isSubset(of: ["pane", "dir"]) })
    }

    @Test func newPaneAndNewColumn() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        _ = try await backend.newPane(from: 2, column: false, in: workspace)
        _ = try await backend.newPane(from: 2, column: true, in: workspace)
        #expect(seen.commands == ["new-pane", "new-pane-right"])
        #expect(seen.mutations.allSatisfy { $0["pane"] as? Int == 2 && $0.count == 3 })
    }

    @Test func zoomSwapRenameAndClose() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        try await backend.toggleZoom(2, in: workspace)
        try await backend.swap(2, .down, in: workspace)
        try await backend.renamePane(3, to: "tests", in: workspace)
        try await backend.closePane(3, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["zoom-pane", "swap-pane", "rename-pane", "close-pane", "close-terminal", "close-terminal"])
        #expect(lines[0]["pane"] as? Int == 2 && lines[0]["mode"] as? String == "toggle")
        #expect(lines[1]["dir"] as? String == "down")
        #expect(lines[2]["name"] as? String == "tests")
        #expect(lines[3]["pane"] as? Int == 3)
        // The pane's terminals end with it, as a phone-closed tab's does.
        #expect(Set(lines[4...].compactMap { $0["terminal_id"] as? String }) == ["term_c", "term_d"])
    }

    @Test func aPaneThatIsGoneIsRefusedBeforeTheMac() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        await #expect(throws: WorkspaceCreationError.self) { try await backend.toggleZoom(99, in: workspace) }
        #expect(seen.commands.isEmpty)
    }

    @Test func equalizeSendsOnlyTheUnequalSplitsInOneTransaction() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        #expect(try await backend.equalizeSplits(in: workspace) == 1)
        let line = try #require(seen.mutations.first)
        #expect(seen.commands == ["set-split-ratio"])
        #expect(line["split"] as? Int == 7)
        #expect(line["ratio"] as? Double == 0.5)
        #expect(line["transaction"] as? Int != nil)
    }

    @Test func undoThatClosesPanesAsksThenConfirmsWithTheRevision() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let first = try await backend.undoLayout(in: workspace, confirming: nil)
        #expect(first == .needsConfirmation(revision: 8, closing: 1))
        #expect(try await backend.undoLayout(in: workspace, confirming: 8) == .undone)
        let lines = seen.mutations
        #expect(seen.commands == ["undo-layout", "undo-layout"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0]["confirm_close"] == nil)
        #expect(lines[1]["revision"] as? Int == 8 && lines[1]["confirm_close"] as? Bool == true)
    }

    @Test func undoRepliesAreReadStrictly() throws {
        #expect(try LiveWorkspaceCreationBackend.undoOutcome(["data": ["undone": true, "screen": 1, "revision": 2]]) == .undone)
        #expect(throws: WorkspaceCreationError.self) {
            try LiveWorkspaceCreationBackend.undoOutcome(["data": ["undone": true, "confirmation_required": true]])
        }
        #expect(throws: WorkspaceCreationError.self) {
            try LiveWorkspaceCreationBackend.undoOutcome(["data": ["undone": false, "confirmation_required": true, "revision": 3]])
        }
    }

    @Test func moveTabToNewSplitColumnAndPane() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let tab = try #require(workspace.tabs.first { $0.id == "s30" })
        try await backend.moveTab(tab, toNewSplit: .up, in: workspace)
        try await backend.moveTabToNewColumn(tab, in: workspace)
        try await backend.moveTab(tab, toPane: 1, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["move-tab-to-split", "move-tab-to-column", "move-tab"])
        #expect(lines[0]["surface"] as? Int == 30 && lines[0]["pane"] as? Int == 3 && lines[0]["edge"] as? String == "top")
        #expect(lines[1]["surface"] as? Int == 30 && lines[1]["pane"] as? Int == 3)
        // The end of pane 1's four tabs.
        #expect(lines[2]["pane"] as? Int == 1 && lines[2]["index"] as? Int == 4)
    }

    @Test func aPanesOnlyTabIsNotSplitOut() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let only = try #require(workspace.tabs.first { $0.id == "s20" })
        await #expect(throws: WorkspaceCreationError.self) { try await backend.moveTab(only, toNewSplit: .right, in: workspace) }
        #expect(seen.commands.isEmpty)
    }

    @Test func forkToTheRightAndToANewWorkspace() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let chat = try #require(workspace.tabs.first { $0.id == "s12" })
        let copy = try await backend.forkAgentChat(chat, to: .right, in: workspace)
        #expect(copy.id == "s41")
        _ = try await backend.forkAgentChat(chat, to: .workspace, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["new-conversation-tab", "move-tab-to-split", "new-conversation-tab", "move-tab-to-new-workspace"])
        #expect(lines[0]["pane"] as? Int == 1)
        #expect((lines[0]["agent_session"] as? [String: Any])?["session"] as? String == "sess-f")
        #expect(lines[1]["surface"] as? Int == 41 && lines[1]["pane"] as? Int == 1 && lines[1]["edge"] as? String == "right")
        #expect(lines[3]["surface"] as? Int == 41)
    }

    @Test func theMacsForkTitles() {
        #expect(ChatForkDestination.right.macTitle == "Fork Conversation to the Right")
        #expect(ChatForkDestination.allCases.compactMap(\.splitEdge?.daemonEdge) == ["right", "left", "top", "bottom"])
        #expect(PaneSplit.allCases.map(\.title) == ["Split Right", "Split Down", "Split Left", "Split Up"])
    }
}
