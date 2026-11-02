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
        /// What the mock Mac has made so far: a split's new pane 9 (s50), a fork's tab s41.
        private var made: Set<String> = []
        func make(_ thing: String) { lock.withLock { _ = made.insert(thing) } }
        func has(_ thing: String) -> Bool { lock.withLock { made.contains(thing) } }
        /// A tree that replaces the mock Mac's own (another layout, or the Mac after a change).
        private var override: String?
        func setTree(_ tree: String) { lock.withLock { override = tree } }
        var tree: String? { lock.withLock { override } }
    }

    /// The tree as the mock Mac has it now: after a split, pane 9 (s50) right of pane 1; after a
    /// fork, the copy s41 at the end of pane 1.
    nonisolated static func tree(_ seen: Seen) -> String {
        if let override = seen.tree { return override }
        var tree = Self.tree
        if seen.has("fork") {
            tree = tree.replacingOccurrences(of: #"{"surface":12,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-a","harness":"claude"}}}"#,
                                             with: #"{"surface":12,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-a","harness":"claude"}}},{"surface":41,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-f","harness":"claude"}}}"#)
        }
        if seen.has("split") {
            tree = tree.replacingOccurrences(of: #""a":{"type":"leaf","pane":1}"#,
                                             with: #""a":{"type":"split","split":10,"dir":"right","ratio":0.5,"a":{"type":"leaf","pane":1},"b":{"type":"leaf","pane":9}}"#)
                .replacingOccurrences(of: #"{"id":2,"name":"logs""#,
                                      with: #"{"id":9,"name":"","active_tab":0,"tabs":[{"surface":50,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_n"}]},{"id":2,"name":"logs""#)
        }
        return tree
    }

    /// wk1, one screen: pane 1 (left, 70%) holds s10, s11 and the chat s12;
    /// right of it pane 2 (s20) above pane 3 (s30, s40).
    nonisolated static let tree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"id":5,"name":"","active":true,"active_pane":1,"zoomed_pane":null,
        "layout":{"type":"split","split":7,"dir":"right","ratio":0.7,"a":{"type":"leaf","pane":1},
                  "b":{"type":"split","split":8,"dir":"down","ratio":0.5,"a":{"type":"leaf","pane":2},"b":{"type":"leaf","pane":3}}},
        "panes":[
        {"id":1,"name":null,"active_tab":1,"tabs":[
          {"surface":10,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_a"},
          {"surface":11,"kind":"pty","title":"build","dead":false,"terminal_id":"term_b"},
          {"surface":12,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-a","harness":"claude"}}}]},
        {"id":2,"name":"logs","active_tab":0,"tabs":[{"surface":20,"kind":"pty","title":"tail","dead":false,"terminal_id":"term_l"}]},
        {"id":3,"name":"","active_tab":0,"tabs":[
          {"surface":30,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_c"},
          {"surface":40,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_d"}]}]}]}
    ]}
    """#

    /// wk1 after the Mac switched screens: screen 5 (panes 1 to 3) is in the background and
    /// screen 6 (pane 60) is shown.
    nonisolated static let switchedTree = Self.tree
        .replacingOccurrences(of: #""screens":[{"id":5,"name":"","active":true"#, with: #""screens":[{"id":5,"name":"","active":false"#)
        .replacingOccurrences(of: #""terminal_id":"term_d"}]}]}]}"#, with: #""terminal_id":"term_d"}]}]},\#(screenSix)]}"#)

    nonisolated static let screenSix = #"""
    {"id":6,"name":"two","active":true,"active_pane":60,"zoomed_pane":null,"layout":{"type":"leaf","pane":60},
     "panes":[{"id":60,"name":"","active_tab":0,"tabs":[{"surface":60,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_s"}]}]}
    """#

    /// wk1 in viewport columns: a chat dock floating over the left edge, 90% of the viewport wide (pane 64),
    /// then three scrolling columns, each two thirds of the viewport wide (panes 61, 62, 63). The
    /// screen's `layout` is the compatibility chain that squeezes them all into one width.
    nonisolated static let columnsTree = #"""
    {"workspaces":[
      {"id":1,"key":"wk1","name":"main","screens":[{"id":5,"name":"","active":true,"active_pane":61,"zoomed_pane":null,
        "layout":{"type":"split","split":70,"dir":"right","ratio":0.5,"a":{"type":"leaf","pane":64},
                  "b":{"type":"split","split":71,"dir":"right","ratio":0.3333,"a":{"type":"leaf","pane":61},
                       "b":{"type":"split","split":72,"dir":"right","ratio":0.5,"a":{"type":"leaf","pane":62},"b":{"type":"leaf","pane":63}}}},
        "viewport_base_width":0.9,
        "columns":[
          {"id":80,"width":0.9,"layout":{"type":"leaf","pane":64},"dock":{"edge":"left","mode":"overlay","role":"agent_chat"}},
          {"id":81,"width":0.6667,"layout":{"type":"leaf","pane":61}},
          {"id":82,"width":0.6667,"layout":{"type":"leaf","pane":62}},
          {"id":83,"width":0.6667,"layout":{"type":"leaf","pane":63}}],
        "panes":[
        {"id":64,"name":"","active_tab":0,"tabs":[{"surface":64,"kind":"pty","title":"chat","dead":false,"terminal_id":"term_x"}]},
        {"id":61,"name":"","active_tab":0,"tabs":[{"surface":61,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_p"}]},
        {"id":62,"name":"","active_tab":0,"tabs":[{"surface":62,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_q"}]},
        {"id":63,"name":"","active_tab":0,"tabs":[{"surface":63,"kind":"pty","title":"zsh","dead":false,"terminal_id":"term_r"}]}]}]}
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
                    line = #"{"id":"\#(id)","ok":true,"data":\#(tree(seen).replacingOccurrences(of: "\n", with: ""))}"#
                case "list-agents":
                    line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
                case "split", "new-pane-right":
                    seen.make("split")
                    line = #"{"id":"\#(id)","ok":true,"data":{"surface":50}}"#
                case "new-conversation-tab":
                    seen.make("fork")
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
        #expect(layout.pane(1)?.tabIDs == ["s10", "s11", "s12"])
        #expect(layout.pane(3)?.tabCount == 2)
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
        // Split Left: the daemon's split right, then the old pane swaps with the new one (pane 9,
        // which the Mac lists only after the split).
        let tab = try await backend.split(1, .left, in: workspace)
        #expect(tab.id == "s50")
        _ = try await backend.split(2, .down, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["split", "swap-pane", "split"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0]["dir"] as? String == "right")
        #expect(lines[1]["pane"] as? Int == 1 && lines[1]["target"] as? Int == 9)
        #expect(lines[2]["pane"] as? Int == 2 && lines[2]["dir"] as? String == "down")
        // Only the lane's creation fields: no program, folder or environment.
        #expect(lines.filter { $0["cmd"] as? String == "split" }.allSatisfy { Set($0.keys).subtracting(["id", "cmd"]).isSubset(of: ["pane", "dir"]) })
    }

    /// New Pane (Auto Layout) is the Mac's: the largest pane (pane 1, 70% wide) splits along its
    /// longer side; never the daemon's `new-pane`. New Column is `new-pane-right`.
    @Test func newPaneSplitsTheLargestPaneAndNewColumn() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        _ = try await backend.newPane(from: 2, column: false, in: workspace)
        _ = try await backend.newPane(from: 2, column: true, in: workspace)
        let lines = seen.mutations
        #expect(seen.commands == ["split", "new-pane-right"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0]["dir"] as? String == "right")
        #expect(lines[1]["pane"] as? Int == 2 && lines[1].count == 3)
    }

    /// Viewport columns are as wide as the Mac draws them (`columns[].width` of its viewport), not
    /// the compatibility chain's share of one width: three columns two thirds of a viewport wide
    /// are each 10.67 by 10 in a 16:10 window, so the first one splits right. The chat dock (an
    /// overlay, so the strip keeps the full width) is never split, as on the Mac.
    @Test func autoLayoutReadsViewportColumnsAtTheirWidths() async throws {
        let seen = Seen()
        seen.setTree(Self.columnsTree.replacingOccurrences(of: "\n", with: ""))
        let (backend, workspace) = try await connected(seen)
        // The mock Mac doesn't list the new pane's tab here; only the line sent matters.
        _ = try? await backend.newPane(from: 62, column: false, in: workspace)
        let line = try #require(seen.mutations.first)
        #expect(seen.commands.first == "split")
        #expect(line["pane"] as? Int == 61)
        #expect(line["dir"] as? String == "right")
    }

    @Test func viewportColumnsReadFromTheScreen() {
        let screen: [String: Any] = [
            "columns": [
                ["id": 1, "width": 0.9, "layout": ["type": "leaf", "pane": 4], "dock": ["edge": "left", "mode": "docked"]],
                ["id": 2, "width": 0.6667, "layout": ["type": "leaf", "pane": 1]],
                ["id": 3, "width": 0.5, "layout": ["type": "leaf", "pane": 9]],
            ],
        ]
        let columns = DaemonTree.columns(screen, without: [9])
        #expect(columns.map(\.dock) == [WorkspaceLayout.Column.Dock(edge: .left), nil])
        #expect(columns.map(\.width) == [0.9, 0.6667])
        #expect(columns.last?.root == .pane(1))
    }

    @Test func autoLayoutMeasuresRowsAtTheirHeights() {
        // One column a viewport wide with two rows: a short one (pane 1, 20%) and a tall one
        // (pane 2, 80%) holding a side by side split (panes 2 and 3, 8 by 8 each). Beside it a
        // narrow column (pane 4, 4 by 10). The left half of the tall row is largest and square:
        // it splits right.
        let rows = WorkspaceLayout.Column(width: 1, root: nil, rows: [
            .init(height: 200, root: .pane(1)),
            .init(height: 800, root: .split(id: 5, axis: .horizontal, ratio: 0.5, first: .pane(2), second: .pane(3))),
        ])
        let narrow = WorkspaceLayout.Column(width: 0.25, root: .pane(4))
        let screen = WorkspaceLayout.Screen(id: 1, isActive: true, panes: [1, 2, 3, 4].map { WorkspaceLayout.Pane(id: $0, tabIDs: []) },
                                            root: nil, columns: [rows, narrow])
        #expect(screen.autoLayoutSplit?.pane == 2)
        #expect(screen.autoLayoutSplit?.direction == .right)
        // Only docked columns' panes have no frame to compare: nothing scrolling is split.
        let docked = WorkspaceLayout.Screen(id: 1, isActive: true, panes: [WorkspaceLayout.Pane(id: 4, tabIDs: [])], root: .pane(4),
                                            columns: [WorkspaceLayout.Column(width: 1, dock: WorkspaceLayout.Column.Dock(edge: .left), root: .pane(4))])
        #expect(docked.autoLayoutSplit == nil)
    }

    /// Docks take their room from the scrolling strip as on the Mac: a docked top band 30% of the
    /// window high leaves two half-width columns 8 by 7, which split right (8 by 10 would split
    /// down). An overlay side dock leaves the strip its full width; a docked one narrows it.
    @Test func autoLayoutLeavesTheDocksRoomOutOfTheStrip() {
        func screen(_ dock: WorkspaceLayout.Column) -> WorkspaceLayout.Screen {
            WorkspaceLayout.Screen(id: 1, isActive: true, panes: [1, 2, 9].map { WorkspaceLayout.Pane(id: $0, tabIDs: []) }, root: nil,
                                   columns: [dock, WorkspaceLayout.Column(width: 0.5, root: .pane(1)), WorkspaceLayout.Column(width: 0.5, root: .pane(2))])
        }
        let band = screen(WorkspaceLayout.Column(width: 0.3, dock: WorkspaceLayout.Column.Dock(edge: .top), root: .pane(9)))
        #expect(band.autoLayoutSplit?.pane == 1)
        #expect(band.autoLayoutSplit?.direction == .right)
        let overlayBand = screen(WorkspaceLayout.Column(width: 0.3, dock: WorkspaceLayout.Column.Dock(edge: .bottom, isOverlay: true), root: .pane(9)))
        #expect(overlayBand.autoLayoutSplit?.direction == .right)
        // A docked left dock half the window wide leaves 8 by 10: the halves are 4 by 10 and split down.
        let docked = screen(WorkspaceLayout.Column(width: 0.5, dock: WorkspaceLayout.Column.Dock(edge: .left), root: .pane(9)))
        #expect(docked.autoLayoutSplit?.pane == 1)
        #expect(docked.autoLayoutSplit?.direction == .down)
        // The same dock floating over the strip leaves it the whole width: halves 8 wide.
        let overlay = screen(WorkspaceLayout.Column(width: 0.5, dock: WorkspaceLayout.Column.Dock(edge: .left, isOverlay: true), root: .pane(9)))
        #expect(overlay.autoLayoutFrames[1]?.width == 8)
        #expect(docked.autoLayoutFrames[1]?.width == 4)
        #expect(band.autoLayoutFrames[1]?.height == 7)
        #expect(band.autoLayoutFrames[1]?.minY == 3)
        #expect(band.autoLayoutFrames[9] == nil)
    }

    @Test func autoLayoutPicksTheLargestPaneAndItsLongerSide() {
        // A tall right half (two stacked quarters beside a half): the half splits; a wide half splits down.
        let tall = WorkspaceLayout.Screen(id: 1, isActive: true, panes: [1, 2, 3].map { WorkspaceLayout.Pane(id: $0, tabIDs: []) },
                                          root: .split(id: 1, axis: .horizontal, ratio: 0.5, first: .pane(1),
                                                       second: .split(id: 2, axis: .vertical, ratio: 0.5, first: .pane(2), second: .pane(3))))
        #expect(tall.autoLayoutSplit?.pane == 1)
        #expect(tall.autoLayoutSplit?.direction == .down)
        let one = WorkspaceLayout.Screen(id: 1, isActive: true, panes: [WorkspaceLayout.Pane(id: 4, tabIDs: [])], root: .pane(4))
        #expect(one.autoLayoutSplit?.pane == 4)
        #expect(one.autoLayoutSplit?.direction == .right)
    }

    @Test func deadPanesLeaveTheTree() {
        let root = WorkspaceLayout.Node.split(id: 1, axis: .horizontal, ratio: 0.5, first: .pane(1),
                                              second: .split(id: 2, axis: .vertical, ratio: 0.5, first: .pane(2), second: .pane(3)))
        #expect(root.removing([3]) == .split(id: 1, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))
        #expect(root.removing([1, 2, 3]) == nil)
        #expect(WorkspaceLayout.Node.stack([4, 5], expanded: 5).removing([5]) == .stack([4], expanded: 4))
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
        let question = LayoutUndoConfirmation(screen: 5, pane: 1, revision: 8, closing: 1)
        #expect(first == .needsConfirmation(question))
        #expect(try await backend.undoLayout(in: workspace, confirming: question) == .undone)
        let lines = seen.mutations
        #expect(seen.commands == ["undo-layout", "undo-layout"])
        #expect(lines[0]["pane"] as? Int == 1 && lines[0]["confirm_close"] == nil)
        #expect(lines[1]["revision"] as? Int == 8 && lines[1]["confirm_close"] as? Bool == true)
    }

    /// The Mac switches screens while the question is open: the yes still goes to the screen the
    /// question was about (its pane), never the screen shown now (revisions count per screen).
    @Test func undoConfirmationStaysOnTheScreenItAskedAbout() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let asked = try await backend.undoLayout(in: workspace, confirming: nil)
        seen.setTree(Self.switchedTree.replacingOccurrences(of: "\n", with: ""))
        _ = try await backend.sync.listNow()
        #expect(backend.sync.tree?.workspaces.first?.layout?.activeScreen?.id == 6)
        guard case .needsConfirmation(let question) = asked else {
            Issue.record("expected a question, got \(asked)")
            return
        }
        #expect(question.screen == 5 && question.pane == 1)
        #expect(try await backend.undoLayout(in: workspace, confirming: question) == .undone)
        let lines = seen.mutations
        #expect(seen.commands == ["undo-layout", "undo-layout"])
        #expect(lines[1]["pane"] as? Int == 1)
        #expect(lines[1]["revision"] as? Int == 8)
    }

    /// The pane the question named left its screen: the yes is refused before the Mac.
    @Test func undoConfirmationForAScreenThatChangedIsRefused() async throws {
        let seen = Seen()
        let (backend, workspace) = try await connected(seen)
        let moved = LayoutUndoConfirmation(screen: 6, pane: 1, revision: 8, closing: 1)
        await #expect(throws: WorkspaceCreationError.self) { try await backend.undoLayout(in: workspace, confirming: moved) }
        let gone = LayoutUndoConfirmation(screen: 5, pane: 99, revision: 8, closing: 1)
        await #expect(throws: WorkspaceCreationError.self) { try await backend.undoLayout(in: workspace, confirming: gone) }
        #expect(seen.commands.isEmpty)
    }

    @Test func undoRepliesAreReadStrictly() throws {
        func outcome(_ data: [String: Any]) throws -> LayoutUndoOutcome {
            try LiveWorkspaceCreationBackend.undoOutcome(["data": data], screen: 5, pane: 1)
        }
        #expect(try outcome(["undone": true, "screen": 5, "revision": 2]) == .undone)
        #expect(try outcome(["undone": false, "confirmation_required": true, "screen": 5, "revision": 3, "closes_panes": [9, 10]])
            == .needsConfirmation(LayoutUndoConfirmation(screen: 5, pane: 1, revision: 3, closing: 2)))
        // The applied variant needs its screen and revision.
        #expect(throws: WorkspaceCreationError.self) { try outcome(["undone": true]) }
        #expect(throws: WorkspaceCreationError.self) { try outcome(["undone": true, "confirmation_required": true]) }
        // A question needs its screen (the one asked about), its revision and the pane ids it closes.
        let question: [String: Any] = ["undone": false, "confirmation_required": true, "screen": 5, "revision": 3, "closes_panes": [9]]
        for broken: [String: Any] in [
            question.filter { $0.key != "screen" },
            question.merging(["screen": 6]) { $1 },
            question.merging(["screen": "5"]) { $1 },
            question.filter { $0.key != "revision" },
            question.merging(["revision": -1]) { $1 },
            question.merging(["closes_panes": [Int]()]) { $1 },
            question.merging(["closes_panes": ["9"]]) { $1 },
            question.merging(["closes_panes": [9.5]]) { $1 },
            question.merging(["closes_panes": [true]]) { $1 },
            question.merging(["closes_panes": [-1]]) { $1 },
        ] {
            #expect(throws: WorkspaceCreationError.self) { try outcome(broken) }
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
        // Past the end of pane 1's three tabs.
        #expect(lines[2]["pane"] as? Int == 1 && lines[2]["index"] as? Int == 3)
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
