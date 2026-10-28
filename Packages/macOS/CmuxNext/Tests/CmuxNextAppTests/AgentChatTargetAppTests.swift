import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
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
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The two-pane window of `CanvasLayoutActionTests`: the first pane keeps its terminal and
    /// the focus; the second shows an agent chat page that never connects.
    @MainActor final class Rig {
        let services: AppServices
        let controller: WindowController
        let terminal: PaneController
        let chat: PaneController
        let chatTab: String
        let directory: URL

        init() async throws {
            let (services, controller, content) = try await CanvasLayoutActionTests.window()
            self.services = services
            self.controller = controller
            let models = try #require(services.machines.local.store.workspaces.first?.screens.first?.panes)
            try #require(models.count == 2)
            terminal = try #require(content.paneController(key: models[0].id))
            chat = try #require(content.paneController(key: models[1].id))
            for _ in 0..<100 where chat.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
            if chat.currentTabKey == nil { chat.showSelected() }
            chatTab = try #require(chat.currentTabKey, "the second pane shows no tab")

            directory = FileManager.default.temporaryDirectory.appending(path: "agent-chat-target-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html")
            try Data("<html><body></body></html>".utf8).write(to: file)
            let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), allowsTabConversion: true), source: .bundled(file)))
            services.agentTabs.views[chatTab] = page

            controller.focus.send(.focusPane(terminal.paneKey, source: .programmatic))
            services.registry.context.remove(.agentPaneFocused)
        }

        func tearDown() {
            services.agentTabs.views[chatTab] = nil
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
            let panes = [ControlPaneInfo(id: terminal.paneKey, handle: "1"),
                         ControlPaneInfo(id: chat.paneKey, handle: "2", selectedTabID: chatTab, tabs: [tab])]
            topology.workspaces = [ControlWorkspaceInfo(id: "canvas-ws", handle: "1", name: "canvas",
                                                        screens: [ControlScreenInfo(id: "screen-1", handle: "1", panes: panes)])]
            return topology
        }

        /// `action.run` of Set Agent Chat Model on `target`, through a router whose snapshot has
        /// `topology` (nil: none loaded yet). It does not wait for the page's reply: the page never
        /// connects, and a run that reached the chat answers `ran` once its handler started.
        func setModel(_ target: String, topology: ControlTopology?) async -> Result<JSONValue, ControlError> {
            let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                       executor: RegistryControlBridge(registry: services.registry),
                                       configuration: .init(requestDeadline: .seconds(30)))
            router.updateCatalog(RegistryControlBridge.catalog(from: services.registry))
            if let topology { router.snapshots.publish { $0.topology = topology } }
            return await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": "agentPane.setModel", "target": .string(target), "args": ["model": "opus"], "wait": false,
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
}
