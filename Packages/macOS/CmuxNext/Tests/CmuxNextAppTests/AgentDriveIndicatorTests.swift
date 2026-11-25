import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextComputerUse
@testable import CmuxNextDesign
@testable import CmuxNextDaemon
import CmuxNextPages
@testable import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// An agent that drives the screen (Computer Use) or a browser shows on its workspace row, its tab and
/// its pane at a glance, without the `sidebar.presenceDots` prototype toggle (Lawrence 2026-11-07: "the
/// computer use/browser use indicator in workspaces needs to be better"). The indicator names the agent
/// and what it drives; quieter activity (editing, reading) stays behind the toggle.
@MainActor
struct AgentDriveIndicatorTests {
    /// One workspace with one terminal tab (surface 1) whose agent reports `activity`.
    static func workspace(_ activity: AgentPresence.Activity?) throws -> WorkspaceModel {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, activeTab: 0, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        _ = store.apply(.agentPresenceChanged(AgentPresence(surface: 1, activity: activity, agent: "claude", session: "claude-1")))
        return try #require(store.workspaces.first)
    }

    @Test(arguments: [(AgentPresence.Activity.computerUse, SidebarPresence.Activity.computerUse),
                      (.browsing, .browsing)])
    func aDrivingAgentReachesItsRowWithTheDotsOff(_ activity: AgentPresence.Activity, _ shown: SidebarPresence.Activity) throws {
        let row = SidebarMapping.shared.row(try Self.workspace(activity), machine: .local)
        let drive = try #require(row.presence.first { $0.activity == shown }, "the row knows the agent drives")
        #expect(drive.id == "claude-1")
        #expect(drive.name != "?")
    }

    @Test func aDrivingAgentReachesItsTabWithTheDotsOff() throws {
        let workspace = try Self.workspace(.computerUse)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.presence?.colorKey == "claude-1", "the tab chip shows the agent that drives")
    }

    @Test func quieterActivityStaysBehindTheToggle() throws {
        let row = SidebarMapping.shared.row(try Self.workspace(.editing), machine: .local)
        #expect(row.presence.isEmpty)
    }

    /// The menu's rows are registered actions (scripts/cmux-next/check-menu-actions.py): Go to is Show Tab on
    /// the agent's tab, Stop is Stop Computer Use on the agent's terminals, as the File menu and the CLI run them.
    @Test func theRowShowsTheDriverAndItsMenuGoesToItsTabAndStopsIt() throws {
        let presence = SidebarMapping.shared.row(try Self.workspace(.computerUse), machine: .local).presence
        let id = WorkspaceID("ws-drive")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var ws = SidebarWorkspace(id: id, title: "drive")
        ws.presence = presence
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(ws)])], activeWorkspaceID: id)
        let services = ForkConversationTests.services()
        AppActions.bind(services)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.driveMenuItem = SidebarBridge.driveMenuItem(services)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let indicator = row.driveIndicator
        #expect(!indicator.isHidden, "an agent using the computer shows on its row with the dots off")
        #expect(indicator.frame.width > 0 && row.bounds.contains(indicator.frame))
        #expect(indicator.accessibilityLabel()?.contains(presence[0].name) == true, "it names the agent")
        #expect(row.hitTest(row.convert(NSPoint(x: indicator.frame.midX, y: indicator.frame.midY), to: row.superview)) === indicator,
                "a click reaches it, not the row")
        let menu = indicator.menu(for: presence[0])
        #expect(menu.items.map(\.title) == [Strings.driveGoTo(presence[0].name), Strings.driveStop(.screen)])
        let tab = try #require(presence[0].tab)
        let runs = menu.items.compactMap { $0.representedObject as? ActionMenuPayload }
        #expect(runs.map(\.id) == ["tab.focus", "computerUseStop"], "each row runs a registered action")
        #expect(runs.first?.target == ActionTargetRef(kind: .tab, id: tab.rawValue), "Go to shows the agent's tab")
        #expect(runs.last?.arguments["terminals"] != nil, "Stop names the agent's terminals")
        #expect(menu.items.allSatisfy { $0.target is ActionMenuTarget }, "no row runs a handler of its own")
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The row's Stop on an agent chat that drives a browser stops that chat's turn though no window shows its
    /// workspace: the indicator sits on sidebar rows, mostly of workspaces in the background (review of #39609).
    @Test(.timeLimit(.minutes(1))) func stopOnABrowsingChatStopsItsTurnInAWorkspaceNoWindowShows() async throws {
        let services = ForkConversationTests.services()
        AppActions.bind(services)
        let store = services.machines.local.store
        let pane = PaneSnapshot(id: 1, activeTab: 0, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1")])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "away",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
        let tab = try #require(paneModel.tabs.first?.id)
        try #require(services.paneController(for: paneModel) == nil, "a window shows the workspace")
        let directory = FileManager.default.temporaryDirectory.appending(path: "drive-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "s-drive"), source: .bundled(file),
                                              pageHost: true, chromium: nil))
        defer { chat.close() }
        services.agentTabs.views[tab] = chat
        defer { services.agentTabs.views[tab] = nil }
        // A new subscriber's events arrive on a later main-actor turn (the provider's replay flush): read them as a stream.
        let (kinds, sink) = AsyncStream.makeStream(of: String.self)
        let provider = try #require(chat.pageEvents)
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                         context: PageCallContext(page: PageDescriptor.agent.id)) { event in
            if case .string(let kind)? = event["kind"] { sink.yield(kind) }
        }
        defer { subscription.cancel(); sink.finish() }
        let item = try #require(SidebarBridge.driveMenuItem(services)(WorkspaceID("away"), .stop(tab: TabID(tab), drive: .browser),
                                                                      Strings.driveStop(.browser)))
        let refusal = services.registry.capturingRefusal { _ = item.target?.perform(item.action, with: item) }
        try #require(refusal == nil, "the row's Stop was refused")
        // The page gets the stop as an event; the test's time limit ends the wait when it never comes.
        for await kind in kinds where kind == "stopTurn" { return }
        Issue.record("the chat's turn did not stop")
    }

    @Test(arguments: SidebarDriveIndicatorVariant.allCases)
    func everyLookDrawsAndNamesTheAgent(_ variant: SidebarDriveIndicatorVariant) {
        _ = NSApplication.shared
        let view = AgentDriveIndicatorView()
        view.makeItem = { _, title in NSMenuItem(title: title, action: nil, keyEquivalent: "") }
        let driver = SidebarPresence(id: "claude-1", name: "Claude Code 2", activity: .browsing, tab: TabID("tab_1"))
        view.configure([driver, SidebarPresence(id: "x", name: "Codex", activity: .editing)], variant: variant)
        #expect(view.drivers == [driver], "only drivers show")
        #expect(view.preferredWidth > 0 && view.preferredHeight > 0)
        #expect(view.menu(for: driver).items.map(\.title) == [Strings.driveGoTo("Claude Code 2")],
                "a terminal agent's browser use offers no Stop")
        view.configure([], variant: variant)
        #expect(view.isHidden)
    }

    @Test func theCapsuleShortensTheAgentsName() {
        #expect(AgentDriveIndicatorView.shortName("Claude Code") == "Claude")
        #expect(AgentDriveIndicatorView.shortName("Claude Code 2") == "Claude 2")
        #expect(AgentDriveIndicatorView.shortName("Codex") == "Codex")
    }

    /// The row's Stop is Stop Computer Use (`computerUseStop`, one path with the File menu and the CLI) given the
    /// agent's terminals: the session that agent started stops, not the newest; with none of its own, the newest.
    @Test(arguments: [("term_x,term_old", "cua_old"), ("term_unknown", "cua_new"), ("", "cua_new")])
    func stopEndsTheSessionTheAgentsTerminalStarted(_ terminals: String, _ stopped: String) async {
        let sessions = ComputerUseSessionActionsTests.FakeSessions([ComputerUseSessionActionsTests.older, ComputerUseSessionActionsTests.newer])
        let registry = ComputerUseSessionActionsTests.registry(sessions, ComputerUseSessionActionsTests.FakeFocus())
        let work = registry.capturingWork {
            _ = registry.perform("computerUseStop", invocation: ActionInvocation(arguments: ["terminals": .string(terminals)]))
        }
        for task in work {
            #expect(await task.value == nil)
        }
        #expect(sessions.stopped == [stopped])
    }
}
