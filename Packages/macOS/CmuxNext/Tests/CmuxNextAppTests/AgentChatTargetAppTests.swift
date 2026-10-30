import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextControl
import CmuxNextFocus
import CmuxNextSettings
import Foundation
import Testing

/// `cmux agent set-model --target pane:<id>|tab:<id>` with no agent chat focused, end to end:
/// a control router over the App's own registry, so the run passes through the real
/// `WorkspaceSetVerbs` target facts (`ActionRegistry.targetContext`) and the real
/// `AgentConfigurationHandlers.chatView`. The router's snapshot is missing or has not seen
/// the chat yet (startup, a chat that just opened). Before, the router refused such a run
/// from the snapshot before the App could check its live tabs; now the App decides it.
@MainActor @Suite(.serialized)
struct AgentChatTargetAppTests {
    typealias JSONValue = CmuxNextSettings.JSONValue

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Two panes side by side: the first has one terminal tab, the second two tabs.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~"),
                                                                 TabSnapshot(surface: SurfaceID(rawValue: 3), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        // A second workspace no window shows (parked), with one tab.
        let parkedPane = PaneSnapshot(id: PaneID(rawValue: 3), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4), title: "~")])
        let parkedScreen = ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(parkedPane.id), panes: [parkedPane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "chat-target-ws"), name: "chat target", screens: [screen]),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "parked-ws"), name: "parked", screens: [parkedScreen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "chat-target-ws"), index: 0),
                                                   PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "parked-ws"), index: 1)])
        return tree
    }

    /// One window on `tree()` (as `CanvasLayoutActionTests.window()`): the first pane keeps its
    /// terminal and the focus; the second shows an agent chat page that never connects, with a
    /// terminal tab behind it.
    @MainActor final class Rig {
        let services: AppServices
        let controller: WindowController
        let terminal: PaneController
        let chat: PaneController
        let chatTab: String
        /// The second pane's other tab, a terminal its pane does not show.
        let behindTab: String
        /// The tab of the workspace no window shows, with a cached chat page of its own.
        let parkedTab: String
        let directory: URL

        init() async throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(services)
            services.windows.ordersWindowsIn = false
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: AgentChatTargetAppTests.tree())
            let controller = try #require(services.windows.openWindow(workspaces: ["chat-target-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
            self.services = services
            self.controller = controller
            for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
            let content = try #require(controller.workspaceContent)
            try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
            content.contentView.layoutSubtreeIfNeeded()
            let models = try #require(store.workspaces.first { $0.key == WorkspaceKey(rawValue: "chat-target-ws") }?.screens.first?.panes)
            try #require(models.count == 2)
            terminal = try #require(content.paneController(key: models[0].id))
            chat = try #require(content.paneController(key: models[1].id))
            for _ in 0..<100 where chat.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
            if chat.currentTabKey == nil { chat.showSelected() }
            let shown = try #require(chat.currentTabKey, "the second pane shows no tab")
            chatTab = shown
            behindTab = try #require(models[1].tabs.first { $0.id != shown }?.id, "the second pane has no second tab")
            let parked = try #require(store.workspaces.first { $0.key == WorkspaceKey(rawValue: "parked-ws") }?.screens.first?.panes.first)
            try #require(services.paneController(for: parked) == nil, "a window shows the parked workspace")
            parkedTab = try #require(parked.tabs.first?.id, "the parked workspace has no tab")

            directory = FileManager.default.temporaryDirectory.appending(path: "agent-chat-target-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html")
            try Data("<html><body></body></html>".utf8).write(to: file)
            let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), allowsTabConversion: true), source: .bundled(file)))
            services.agentTabs.views[chatTab] = page
            services.agentTabs.views[parkedTab] = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), allowsTabConversion: true),
                                                                             source: .bundled(file)))

            controller.focus.send(.focusPane(terminal.paneKey, source: .programmatic))
            services.registry.context.remove(.agentPaneFocused)
        }

        func tearDown() {
            services.agentTabs.views[chatTab] = nil
            services.agentTabs.views[parkedTab] = nil
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }

        /// The topology as a lagging snapshot shows it: both panes and the chat's tab, with no
        /// chat session on it yet.
        var staleTopology: ControlTopology {
            var topology = ControlTopology()
            topology.isLoaded = true
            topology.daemonState = "connected"
            let tab = ControlTabInfo(id: chatTab, surface: "2", kind: "terminal", title: "~")
            let behind = ControlTabInfo(id: behindTab, surface: "3", kind: "terminal", title: "~")
            let panes = [ControlPaneInfo(id: terminal.paneKey, handle: "1"),
                         ControlPaneInfo(id: chat.paneKey, handle: "2", selectedTabID: chatTab, tabs: [tab, behind])]
            topology.workspaces = [ControlWorkspaceInfo(id: "canvas-ws", handle: "1", name: "canvas",
                                                        screens: [ControlScreenInfo(id: "screen-1", handle: "1", panes: panes)])]
            return topology
        }

        /// A router over the App's registry whose snapshot has `topology` (nil: none loaded yet).
        func router(topology: ControlTopology?) -> ControlRouter {
            let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                       executor: RegistryControlBridge(registry: services.registry),
                                       configuration: .init(requestDeadline: .seconds(30)))
            router.updateCatalog(RegistryControlBridge.catalog(from: services.registry))
            if let topology { router.snapshots.publish { $0.topology = topology } }
            return router
        }

        /// `action.run` of Set Agent Chat Model on `target`. It does not wait for the page's
        /// reply: the page never connects, and a run that reached the chat answers `ran` once its
        /// handler started.
        func setModel(_ target: String, topology: ControlTopology?) async -> Result<JSONValue, ControlError> {
            await router(topology: topology).handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "agentPane.setModel", "target": .string(target), "args": ["model": "opus"], "wait": false,
            ]))
        }

        /// An atomic `action.batch` of Toggle Sidebar and then `second`, not waiting for its work.
        func batchAfterToggleSidebar(_ second: JSONValue, topology: ControlTopology?) async -> Result<JSONValue, ControlError> {
            await router(topology: topology).handle(ControlRequest(id: "1", method: "action.batch", params: [
                "ops": [["action": "toggleSidebar"], second], "wait": false,
            ]))
        }
    }

    @Test(arguments: [false, true])
    func aPaneOrTabShowingAChatTakesTheModelWithNoChatFocused(staleSnapshot: Bool) async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        try #require(!rig.services.registry.context.contains(.agentPaneFocused), "a chat has the keyboard")
        let topology = staleSnapshot ? rig.staleTopology : nil
        for target in ["pane:\(rig.chat.paneKey)", "tab:\(rig.chatTab)"] {
            let reply = await rig.setModel(target, topology: topology)
            guard case .success(let value) = reply else {
                Issue.record("\(target) (stale snapshot: \(staleSnapshot)) was refused: \(reply)")
                continue
            }
            #expect(value["ran"] == true, "\(target): \(value)")
        }
    }

    @Test(arguments: [false, true])
    func aPaneShowingNoChatIsRefusedByTheApp(staleSnapshot: Bool) async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let reply = await rig.setModel("pane:\(rig.terminal.paneKey)", topology: staleSnapshot ? rig.staleTopology : nil)
        guard case .failure(let error) = reply else {
            Issue.record("a terminal pane took a chat's model: \(reply)")
            return
        }
        #expect(error.code == "unavailable", "\(error)")
        #expect(error.data?["not_run"] == true, "\(error)")
    }

    /// The router leaves a pane target's chat and canvas facts to the App, so an atomic batch
    /// checks every op with the App before any runs: one the App would refuse (Set Agent Chat
    /// Model on a terminal pane, a canvas zoom on a pane on no canvas) refuses the batch whole,
    /// and the Toggle Sidebar before it never applies.
    @Test(arguments: [false, true])
    func aBatchWithAnOpTheAppWouldRefuseLeavesTheSidebarAlone(staleSnapshot: Bool) async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let topology = staleSnapshot ? rig.staleTopology : nil
        let pane = JSONValue.string("pane:\(rig.terminal.paneKey)")
        for second: JSONValue in [["action": "agentPane.setModel", "target": pane, "args": ["model": "opus"]],
                                  ["action": "canvasZoomIn", "target": pane]] {
            let hidden = rig.controller.sidebar.model.isHidden
            let reply = await rig.batchAfterToggleSidebar(second, topology: topology)
            guard case .failure(let error) = reply else {
                Issue.record("\(second): the batch ran: \(reply)")
                continue
            }
            #expect(error.code == "unavailable", "\(second): \(error)")
            #expect(error.data?["op"] == 1, "\(second): \(error)")
            #expect(error.data?["not_run"] == true, "\(second): \(error)")
            #expect(rig.controller.sidebar.model.isHidden == hidden, "\(second): Toggle Sidebar applied before the refused op")
        }
    }

    /// A tab target is its own tab, not the chat its pane shows: Set Agent Chat Model on the
    /// terminal tab behind the chat is refused by the App, alone and in a batch, before anything
    /// applies. A parked workspace's tab, whose chat page is cached but no window shows its pane
    /// (the handler cannot act on it), is refused the same way.
    @Test(arguments: [false, true])
    func aTerminalTabBehindAChatIsNotTheChat(staleSnapshot: Bool) async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        await expectRefusedAloneAndInABatch("tab:\(rig.behindTab)", rig, topology: staleSnapshot ? rig.staleTopology : nil)
    }

    @Test func aParkedWorkspacesCachedChatIsRefusedBeforeAnythingApplies() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        await expectRefusedAloneAndInABatch("tab:\(rig.parkedTab)", rig, topology: nil)
    }

    private func expectRefusedAloneAndInABatch(_ target: String, _ rig: Rig, topology: ControlTopology?) async {
        guard case .failure(let alone) = await rig.setModel(target, topology: topology) else {
            Issue.record("\(target) took a chat's model")
            return
        }
        #expect(alone.code == "unavailable", "\(alone)")
        #expect(alone.data?["not_run"] == true, "\(alone)")

        let hidden = rig.controller.sidebar.model.isHidden
        let reply = await rig.batchAfterToggleSidebar(["action": "agentPane.setModel", "target": .string(target), "args": ["model": "opus"]],
                                                      topology: topology)
        guard case .failure(let error) = reply else {
            Issue.record("the batch ran: \(reply)")
            return
        }
        #expect(error.code == "unavailable", "\(error)")
        #expect(error.data?["op"] == 1, "\(error)")
        #expect(error.data?["not_run"] == true, "\(error)")
        #expect(rig.controller.sidebar.model.isHidden == hidden, "Toggle Sidebar applied before the refused op")
    }

    @Test func aBatchWhoseOpsTheAppTakesRunsThemAll() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        let hidden = rig.controller.sidebar.model.isHidden
        let reply = await rig.batchAfterToggleSidebar(["action": "agentPane.setModel", "target": .string("pane:\(rig.chat.paneKey)"),
                                                       "args": ["model": "opus"]], topology: nil)
        guard case .success(let value) = reply else {
            Issue.record("the batch was refused: \(reply)")
            return
        }
        #expect(value["ran"] == 2, "\(value)")
        #expect(rig.controller.sidebar.model.isHidden != hidden, "Toggle Sidebar did not apply")
    }

    /// Another agent chat or a canvas has the keyboard (the global context has
    /// `agentPaneFocused` and `canvasLayout`): a script's target still decides its own facts.
    /// Set Agent Chat Model on the terminal pane, and Canvas Zoom In on a pane on no canvas,
    /// are refused alone and in a batch with nothing applied; the chat pane still runs.
    @Test func aFocusedChatOrCanvasElsewhereDoesNotStandInForTheTarget() async throws {
        let rig = try await Rig()
        defer { rig.tearDown() }
        rig.services.registry.context.formUnion([.agentPaneFocused, .canvasLayout])
        await expectRefusedAloneAndInABatch("pane:\(rig.terminal.paneKey)", rig, topology: nil)
        await expectRefusedAloneAndInABatch("tab:\(rig.behindTab)", rig, topology: nil)

        let hidden = rig.controller.sidebar.model.isHidden
        let zoom = await rig.batchAfterToggleSidebar(["action": "canvasZoomIn", "target": .string("pane:\(rig.terminal.paneKey)")], topology: nil)
        guard case .failure(let error) = zoom else {
            Issue.record("a zoom on a pane on no canvas ran: \(zoom)")
            return
        }
        #expect(error.code == "unavailable", "\(error)")
        #expect(error.data?["not_run"] == true, "\(error)")
        #expect(rig.controller.sidebar.model.isHidden == hidden, "Toggle Sidebar applied before the refused zoom")

        guard case .success = await rig.setModel("pane:\(rig.chat.paneKey)", topology: nil) else {
            Issue.record("the chat pane was refused with a chat focused")
            return
        }
    }
}
