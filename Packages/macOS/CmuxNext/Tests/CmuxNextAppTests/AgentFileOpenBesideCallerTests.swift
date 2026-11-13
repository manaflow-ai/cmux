import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemon

/// Lawrence 2026-11-12: `cmux open <file>` from an agent answered `"placement":"focused_pane"` every time (54 results
/// in 14 days): the `file.open` method passed no caller, so an agent's file opened wherever the person's focus was.
/// The method takes `caller` and places by the one rule (ControlCallerPlacement): the file opens beside the agent's
/// chat, in its own workspace, and the keyboard focus stays where it was. This runs the real method through the app's
/// control router, registry and daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct AgentFileOpenBesideCallerTests {
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func anAgentsFileOpensBesideItsChatAndTheFocusStaysInTheChat() async throws {
        try await ViewerOpenBesideChatTests.withLoneChat { services, root, chat in
            let store = services.daemon.store
            let content = try #require(services.windows.active?.workspaceContent)
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
            // The topology lists the agent's chat (session `chat`): the caller the CLI names.
            try await PasswordManagerRouteTests.until({ router.snapshots.current.topology.tab(id: chat.id) != nil },
                                                      report: { "the snapshot never listed the chat tab \(chat.id)" })

            let file = root.appending(path: "notes.txt")
            let reply = await router.handle(ControlRequest(id: "1", method: "file.open", params: [
                "path": .string(file.path), "origin": "cli", "caller": ["agent_session": "chat"],
            ]))
            let answer: CmuxNextSettings.JSONValue
            switch reply {
            case .success(let value): answer = value
            case .failure(let error):
                Issue.record("file.open was refused: \(error.code) \(error.message)")
                return
            }
            #expect(["beside_caller", "beside_caller_new_column"].contains(answer["placement"]?.stringValue ?? ""),
                    "the reply names another place: \(answer)")

            let opened = { store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.page == "editor" } }
            let chatPane = { services.locateTab(chat.id, onMachine: services.daemon.machineID)?.1 }
            try await PasswordManagerRouteTests.until({
                guard let tab = opened(), let viewer = services.locateTab(model: tab)?.1, let home = chatPane() else { return false }
                return viewer !== home
            }, report: {
                let tab = opened()
                return "editor tab \(String(describing: tab?.id)) in \(String(describing: tab.flatMap { services.locateTab(model: $0)?.1.id })), chat in \(String(describing: chatPane()?.id))"
            })
            // In the agent's own workspace, never in the chat's pane, and the person's keyboard stays in the chat.
            let home = try #require(chatPane())
            #expect(!home.tabs.contains { $0.page == "editor" })
            let viewer = try #require(opened().flatMap { services.locateTab(model: $0)?.1 })
            #expect(store.workspace(containing: viewer.handle) === store.workspace(containing: home.handle))
            try await PasswordManagerRouteTests.until({ content.focusedPane?.selectedTab?.id == chat.id },
                                                      report: { "focused \(String(describing: content.focusedPane?.selectedTab?.id)), the chat is \(chat.id)" })
        }
    }
}
