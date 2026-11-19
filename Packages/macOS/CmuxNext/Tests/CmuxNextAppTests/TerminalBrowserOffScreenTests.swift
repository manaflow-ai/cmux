import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// `cmux browser open URL` run in a terminal while the window shows ANOTHER workspace (the person looks elsewhere
/// while an agent works) opened its page as a tab in the terminal's own pane, selected over the terminal (fleet
/// capture of build ff3b87ce78d6 on cmux23, 2026-11-18: the reply's `pane_id` was the caller's own pane, for a
/// plain shell and for an agent's terminal). The rule that sends a terminal's browser right of it (7a35bded508,
/// db311ade813) measured the window, and a workspace no window shows has nothing to measure. The control router
/// now decides from the topology: the column on the right (a tab in its pane that holds a browser, a split below
/// its lone pane that holds none), never one of another agent, else a new pane right of the terminal; the
/// terminal's own pane keeps its tabs, and the person's view does not change.
///
/// The request is the CLI's own: `openBrowser` aimed at the caller's terminal tab, with that terminal as the
/// caller, through the app's control router, registry and a same-tree daemon.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct TerminalBrowserOffScreenTests {
    /// What is right of the caller's terminal.
    enum Right: String, Sendable, CaseIterable {
        /// Nothing: a plain shell's browser gets a new pane right of it.
        case nothing
        /// A column with a terminal no agent runs in: an agent's browser opens in that column, in a split below
        /// its lone terminal pane, as on screen (Leo 2026-10-31: "you only need the rightmost botom auto split
        /// when there's a terminal that gets opened when there's already a browser, and vice versa").
        case helperColumn
        /// A column that is another agent's home (its chat): an agent's browser gets a new pane, not that column.
        case anotherAgentsColumn
    }

    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), arguments: Right.allCases)
    func aTerminalsBrowserOpensRightOfItWhileNoWindowShowsItsWorkspace(_ right: Right) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let store = services.daemon.store
            let window = try #require(services.windows.active)
            try await PasswordManagerRouteTests.until({ window.focusedPane != nil }, report: { "the first workspace never showed a pane" })
            let callerPane = try #require(window.focusedPane).pane
            // The terminal the CLI runs in.
            let shell = try await connection.newTab(in: callerPane.handle).surface
            try await PasswordManagerRouteTests.until({ callerPane.tabs.contains { $0.surface == shell && $0.terminalID != nil } },
                                                      report: { "the caller's terminal has no id: \(callerPane.tabs.map { "\($0.id) \($0.kind)" })" })
            let terminal = try #require(callerPane.tabs.first { $0.surface == shell })
            let terminalID = try #require(terminal.terminalResourceID?.rawValue ?? terminal.terminalID?.rawValue)
            let workspace = try #require(store.workspace(containing: callerPane.handle))

            // The column on its right, made while a window still shows the workspace.
            var rightPane: PaneModel?
            if right != .nothing {
                try await connection.newColumn(rightOf: callerPane.handle)
                @MainActor func made() -> PaneModel? {
                    workspace.screens.flatMap(\.panes).first { $0 !== callerPane && $0.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) } }
                }
                try await PasswordManagerRouteTests.until({ made() != nil }, report: { "the column on the right was not made" })
                rightPane = made()
            }
            if right == .anotherAgentsColumn, let pane = rightPane {
                let host = AgentSessionRef.host(installID: "cn-terminal-browser")
                services.agentTabs.localHost = host
                let chat = try await connection.request(NewConversationTabRequest(
                    agentSession: AgentSessionRef(host: host, session: "another-agent", harness: "codex"), pane: pane.handle))
                try await PasswordManagerRouteTests.until({ pane.tabs.contains { $0.surface == chat.surface } },
                                                          report: { "the other agent's chat is not in the column on the right" })
            }

            // The person looks at Home: no window shows the caller's workspace.
            let (_, home) = try await HomeSplitKeysTests.showHome(services, connection)
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
            // The snapshot lists the caller's terminal, the column on its right, and no window on its workspace.
            @MainActor func published() -> Bool {
                let topology = router.snapshots.current.topology
                guard topology.tab(id: terminal.id) != nil, !topology.windows.contains(where: { $0.workspaceID == workspace.id }) else { return false }
                return rightPane.map { pane in topology.workspaces.contains { $0.panes.contains { $0.id == pane.id && $0.tabs.count == pane.tabs.count } } } ?? true
            }
            try await PasswordManagerRouteTests.until({ published() }, report: { "the snapshot never showed the caller's workspace off screen" })

            let panesBefore = workspace.screens.flatMap(\.panes)
            let tabsBefore = Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
            let callerTabs = callerPane.tabs.map(\.id)
            // An agent is a caller of the cmux MCP server; the plain shell is the cmux CLI a person typed.
            let reply = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "openBrowser", "target": .string("tab:" + terminal.id), "args": ["url": "http://127.0.0.1:9/off-screen"],
                "caller": ["terminal_id": .string(terminalID)], "origin": .string(right == .nothing ? "cli" : "mcp"), "wait": true,
            ]))
            if case .failure(let error) = reply { Issue.record("openBrowser was refused: \(error.code) \(error.message)") }

            @MainActor func opened() -> (TabModel, PaneModel)? {
                for pane in store.workspaces.flatMap(\.screens).flatMap(\.panes) {
                    if let tab = pane.tabs.first(where: { !tabsBefore.contains($0.id) && $0.kind == .browser && !ProvisionalTab.isProvisional($0.id) }) {
                        return (tab, pane)
                    }
                }
                return nil
            }
            @MainActor func describe() -> String {
                let panes = workspace.screens.flatMap(\.panes).map { "\($0.id): \($0.tabs.map { "\($0.kind)" })" }
                return "caller \(callerPane.id), right \(rightPane?.id ?? "none"), panes \(panes)"
            }
            try await PasswordManagerRouteTests.until({ opened().map { $0.1 !== callerPane } ?? false },
                                                      report: { "the browser is not in a pane right of the terminal: " + describe() })
            let (_, landed) = try #require(opened())
            #expect(store.workspace(containing: landed.handle) === workspace, "the browser left the caller's workspace: \(describe())")
            switch right {
            case .nothing:
                #expect(!panesBefore.contains { $0 === landed }, "a plain shell's browser gets a new pane right of it: \(describe())")
            case .helperColumn:
                #expect(!panesBefore.contains { $0 === landed }, "a lone terminal pane keeps its tabs: \(describe())")
                let below = rightPane.flatMap { BesidePaneReuseOffScreenTests.split(of: workspace, between: $0, and: landed) }
                #expect(below == .down, "an agent's browser splits below the lone pane of the column on its right, never beside it: \(describe())")
            case .anotherAgentsColumn:
                #expect(!panesBefore.contains { $0 === landed }, "another agent's column is never where it opens: \(describe())")
            }
            // The terminal's own pane holds what it held, and the person still looks at Home.
            #expect(callerPane.tabs.map(\.id) == callerTabs, "the terminal's own pane changed: \(describe())")
            #expect(window.state.workspaceID == home.id, "the person's view left Home")
        }
    }
}
