import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// While no window showed a terminal's workspace, every `cmux browser open` from it made one more pane: after a
/// plain shell's open and two agent opens the workspace had three browser panes side by side, and `system.identify`
/// still said `beside: {pane: null, placement: "new_column"}` with a browser pane directly right of the terminal
/// (fleet capture of build 76840bfee0ac on cmuxs-mac-mini-6, 2026-11-18). The pane the app makes beside a terminal
/// is a split of the terminal's own column, and the control topology knew columns only, so off screen (no frames
/// to measure) nothing found that pane again. Lawrence's rule, and Leo's of 2026-10-31: reuse the pane on the
/// right, never a third column.
///
/// The topology now names what is directly right of a pane from the daemon's layout, splits included, and the app
/// reads the same layout for a pane no window shows. These run the CLI's and the MCP server's own requests through
/// the app's control router, registry and a same-tree daemon, with the person looking at Home.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct BesidePaneReuseOffScreenTests {
    /// What is directly right of the caller's terminal before it opens anything.
    enum Right: String, Sendable, CaseIterable {
        /// Nothing: the first open makes the pane, the second must find it.
        case nothing
        /// A pane split off the terminal's own pane, with a plain terminal in it.
        case splitTerminal
        /// A pane split off the terminal's own pane that is another agent's home (its chat).
        case splitOfAnotherAgent
    }

    /// One app with the caller's terminal in a workspace no window shows, and a control router on it.
    @MainActor struct Scene {
        let services: AppServices
        let router: ControlRouter
        let workspace: WorkspaceModel
        let callerPane: PaneModel
        let terminal: TabModel
        let terminalID: String
        /// The pane split off the caller's before the run, if any.
        let rightPane: PaneModel?

        var panes: [PaneModel] { workspace.screens.flatMap(\.panes) }
        func browserTabs(_ pane: PaneModel) -> [TabModel] { pane.tabs.filter { $0.kind == .browser && !ProvisionalTab.isProvisional($0.id) } }
        var browserPanes: [PaneModel] { panes.filter { !browserTabs($0).isEmpty } }
        var described: String {
            "caller \(callerPane.id), right \(rightPane?.id ?? "none"), panes " + panes.map { "\($0.id): \($0.tabs.map { "\($0.kind)" })" }.joined(separator: ", ")
        }

        /// The topology lists `pane` with every tab the store holds in it: the next request is placed from it.
        func published(_ pane: PaneModel) -> Bool {
            router.snapshots.current.topology.workspaces.contains { $0.panes.contains { $0.id == pane.id && $0.tabs.count == pane.tabs.count } }
        }

        /// `action` as the caller's terminal runs it: `cli` is a person's shell, `mcp` an agent.
        func run(_ action: String, origin: String, args: [String: CmuxNextSettings.JSONValue] = [:], aimedAtOwnTab: Bool = false) async {
            var params: [String: CmuxNextSettings.JSONValue] = ["action": .string(action), "args": .object(args), "caller": ["terminal_id": .string(terminalID)],
                                               "origin": .string(origin), "wait": true]
            if aimedAtOwnTab { params["target"] = .string("tab:" + terminal.id) }
            let reply = await router.handle(ControlRequest(id: UUID().uuidString, method: "action.run", params: params))
            if case .failure(let error) = reply { Issue.record("\(action) was refused: \(error.code) \(error.message)") }
        }

        /// `cmux browser open URL`: `openBrowser` aimed at the caller's own terminal tab.
        func openBrowser(origin: String, _ path: String) async {
            await run("openBrowser", origin: origin, args: ["url": .string("http://127.0.0.1:9/" + path)], aimedAtOwnTab: true)
        }
    }

    /// The direction of the split whose halves hold `first` and `second`; nil when no split tree holds both.
    static func split(in node: LayoutNode, between first: PaneID, and second: PaneID) -> SplitDirection? {
        guard case .split(_, _, let direction, _, let a, let b) = node else { return nil }
        let (left, right) = (a.paneIDs, b.paneIDs)
        if (left.contains(first) && right.contains(second)) || (left.contains(second) && right.contains(first)) { return direction }
        return split(in: a, between: first, and: second) ?? split(in: b, between: first, and: second)
    }

    static func split(of workspace: WorkspaceModel, between first: PaneModel, and second: PaneModel) -> SplitDirection? {
        for screen in workspace.screens {
            for tree in [screen.layout] + screen.columns.map(\.layout) {
                if let direction = split(in: tree, between: first.handle, and: second.handle) { return direction }
            }
        }
        return nil
    }

    static func withScene(_ right: Right, _ body: @MainActor (Scene) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until({ window.focusedPane != nil }, report: { "the first workspace never showed a pane" })
            let callerPane = try #require(window.focusedPane).pane
            let shell = try await connection.newTab(in: callerPane.handle).surface
            try await PasswordManagerRouteTests.until({ callerPane.tabs.contains { $0.surface == shell && $0.terminalID != nil } },
                                                      report: { "the caller's terminal has no id: \(callerPane.tabs.map { "\($0.id) \($0.kind)" })" })
            let terminal = try #require(callerPane.tabs.first { $0.surface == shell })
            let terminalID = try #require(terminal.terminalResourceID?.rawValue ?? terminal.terminalID?.rawValue)
            let workspace = try #require(store.workspace(containing: callerPane.handle))

            // The pane on its right is a split of the caller's own pane, made while a window still shows the workspace.
            var rightPane: PaneModel?
            if right != .nothing {
                try await connection.split(callerPane.handle, direction: .right)
                @MainActor func made() -> PaneModel? {
                    workspace.screens.flatMap(\.panes).first { $0 !== callerPane && $0.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }
                }
                try await PasswordManagerRouteTests.until({ made() != nil }, report: { "the split on the right was not made" })
                rightPane = made()
            }
            if right == .splitOfAnotherAgent, let pane = rightPane {
                let host = AgentSessionRef.host(installID: "cn-beside-reuse")
                services.agentTabs.localHost = host
                let chat = try await connection.request(NewConversationTabRequest(
                    agentSession: AgentSessionRef(host: host, session: "another-agent", harness: "codex"), pane: pane.handle))
                try await PasswordManagerRouteTests.until({ pane.tabs.contains { $0.surface == chat.surface } },
                                                          report: { "the other agent's chat is not in the pane on the right" })
            }

            // The person looks at Home: no window shows the caller's workspace.
            _ = try await HomeSplitKeysTests.showHome(services, connection)
            try await PasswordManagerRouteTests.until({ services.paneController(for: callerPane) == nil },
                                                      report: { "the caller's workspace is still on screen" })

            // A control router wired the way the app wires its own (CloudCLIActionRun).
            let bridge = RegistryControlBridge(registry: services.registry)
            let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                                 processID: getpid()),
                                       executor: bridge, settings: nil,
                                       configuration: ControlRouter.Configuration(requestDeadline: .seconds(60)), frameSource: CloudCLIActionRun.Frames())
            bridge.attach(to: router)
            defer { bridge.detach() }
            let publisher = ControlSnapshotPublisher(router: router, services: services, frames: CloudCLIActionRun.Frames(), notifications: NotificationCenter())
            publisher.start()
            defer { publisher.stop() }
            let scene = Scene(services: services, router: router, workspace: workspace, callerPane: callerPane, terminal: terminal,
                              terminalID: terminalID, rightPane: rightPane)
            try await PasswordManagerRouteTests.until({
                let topology = router.snapshots.current.topology
                return topology.tab(id: terminal.id) != nil && !topology.windows.contains { $0.workspaceID == workspace.id }
                    && (rightPane.map { scene.published($0) } ?? true)
            }, report: { "the snapshot never showed the caller's workspace off screen" })
            try await body(scene)
        }
    }

    /// (a) and (b): a second browser is a tab in the pane the first one got, and `system.identify` names that pane.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), arguments: Right.allCases)
    func aSecondBrowserIsATabInThePaneTheFirstOneGot(_ right: Right) async throws {
        try await Self.withScene(right) { scene in
            let before = scene.panes
            let callerTabs = scene.callerPane.tabs.map(\.id)
            let othersTabs = scene.rightPane?.tabs.map(\.id)
            // A person's shell first, as in the capture; beside another agent's pane both are the agent's own.
            await scene.openBrowser(origin: right == .splitOfAnotherAgent ? "mcp" : "cli", "first")
            try await PasswordManagerRouteTests.until({ scene.browserPanes.count == 1 }, report: { "the first browser has no pane: " + scene.described })
            let first = try #require(scene.browserPanes.first)
            #expect(first !== scene.callerPane, "never the terminal's own pane: \(scene.described)")
            #expect(!before.contains { $0 === first }, "a new pane, right of the terminal or below the pane that holds no browser: \(scene.described)")
            if let other = scene.rightPane, right == .splitTerminal {
                #expect(Self.split(of: scene.workspace, between: other, and: first) == .down, "below the lone pane on the right, not one more beside it: \(scene.described)")
            }
            try await PasswordManagerRouteTests.until({ scene.published(first) }, report: { "the snapshot never listed the first browser's pane" })

            // (b) `beside` names that pane: the CLI and the MCP server place a new terminal from it.
            let identify = try await scene.router.handle(ControlRequest(id: "identify", method: "system.identify", params: [
                "caller": ["terminal_id": .string(scene.terminalID)], "origin": "mcp",
            ])).get()
            #expect(identify["beside"]?["placement"] == "existing_column", "\(String(describing: identify["beside"]))")
            let named = identify["beside"]?["panes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
            #expect(named.contains(first.id), "the pane the first open made is beside the terminal: \(named), \(scene.described)")
            if right == .nothing { #expect(identify["beside"]?["pane"] == .string(first.id)) }

            // (a) and (d): the next open, an agent's, is a tab in that pane.
            await scene.openBrowser(origin: "mcp", "second")
            try await PasswordManagerRouteTests.until({ scene.browserPanes.flatMap { scene.browserTabs($0) }.count == 2 },
                                                      report: { "the second browser did not open: " + scene.described })
            #expect(scene.browserPanes.count == 1, "one browser pane, never another one beside it: \(scene.described)")
            #expect(scene.browserTabs(first).count == 2, "both browsers are tabs of the pane the first one got: \(scene.described)")
            #expect(scene.panes.count == before.count + 1, "one new pane in all: \(scene.described)")
            #expect(scene.callerPane.tabs.map(\.id) == callerTabs, "the terminal's own pane changed: \(scene.described)")
            if right == .splitOfAnotherAgent { #expect(scene.rightPane?.tabs.map(\.id) == othersTabs, "another agent's pane took a tab: \(scene.described)") }
        }
    }

    /// (c): an agent's new terminal, with one browser pane on its right, opens in a split below that pane (Leo
    /// 2026-10-31: "you only need the rightmost botom auto split when there's a terminal that gets opened when
    /// there's already a browser, and vice versa"), not in one more pane beside it.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anAgentsTerminalSplitsBelowTheLoneBrowserPaneOnItsRight() async throws {
        try await Self.withScene(.nothing) { scene in
            await scene.openBrowser(origin: "mcp", "page")
            try await PasswordManagerRouteTests.until({ scene.browserPanes.count == 1 }, report: { "the browser has no pane: " + scene.described })
            let browser = try #require(scene.browserPanes.first)
            try await PasswordManagerRouteTests.until({ scene.published(browser) }, report: { "the snapshot never listed the browser's pane" })
            let before = scene.panes
            let callerTabs = scene.callerPane.tabs.map(\.id)

            await scene.run("newSurface", origin: "mcp")
            @MainActor func made() -> PaneModel? {
                scene.panes.first { pane in !before.contains { $0 === pane } && pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional($0.id) } }
            }
            try await PasswordManagerRouteTests.until({ made() != nil }, report: { "the agent's terminal got no pane of its own: " + scene.described })
            let below = try #require(made())
            #expect(Self.split(of: scene.workspace, between: browser, and: below) == .down,
                    "a split below the browser pane, not a third pane beside it: \(scene.described)")
            #expect(scene.browserTabs(browser).count == 1, "the browser pane keeps its page: \(scene.described)")
            #expect(scene.callerPane.tabs.map(\.id) == callerTabs, "the terminal's own pane changed: \(scene.described)")
            #expect(scene.panes.count == before.count + 1, "one new pane: \(scene.described)")
        }
    }
}
