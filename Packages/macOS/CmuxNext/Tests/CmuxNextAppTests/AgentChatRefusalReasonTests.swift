import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// An agent-chat action that can't run says why in its own words: its title and its cause, never
/// Dictation's reason (a capture's Continue After Error came back "Dictation works in agent chats").
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentChatRefusalReasonTests {
    nonisolated static let chatActions: [ActionID] = [
        "agentPane.toggleDisplaySettings", "agentPane.replayConversation", "agentPane.editInstructions",
        "agentPane.addProjectFiles", "agentPane.markUnread", "agentPane.moveToFloatingChat",
        "agentPane.continueAfterError", "agentPane.toggleMinimap", "agentPane.revealCwdInFinder",
        "agentPane.openCwdInTerminal", "agentPane.openCwdInEditor", "agentPane.openCwdInApp", "agentPane.copyCwdPath",
        "agentPane.createCheckpoint", "agentPane.setModel",
    ]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        AppActions.bind(services)
        return services
    }

    /// A person's run with an agent chat's key context, but no chat in any pane.
    static func noChatRun() -> ActionInvocation {
        var invocation = ActionInvocation(arguments: ["model": .string("opus")], origin: .user)
        // Create Checkpoint also needs a checkpoint to be capturable, or the registry turns it away first.
        invocation.keyContext = [.agentPaneFocused, .checkpointCaptureAvailable]
        return invocation
    }

    @Test(arguments: chatActions)
    func aChatActionWithNoChatNamesItselfNotDictation(_ id: ActionID) throws {
        let services = Self.services()
        let title = try #require(services.registry.descriptor(for: id)?.title)
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: Self.noChatRun())
        }
        let reason = try #require(refusal, "\(id) ran with no chat")
        #expect(reason != MiscHandlerStrings.noAgentChat, "\(id) refused with Dictation's reason")
        // With no pane at all, a tab action's no-pane reason ("Click a tab first, then try again.") is the honest one too.
        #expect(reason.contains(title) || reason == MiscHandlerStrings.noPane, "\(id): \"\(reason)\" does not name \(title)")
    }

    /// Off a chat, a chat action is disabled where it runs: its shortcut or menu run does nothing,
    /// never a toast that says to go focus a chat (Leo 2026-11-17: "just... stop showijg the toggle").
    @Test(arguments: chatActions)
    func aChatActionWithNoChatShowsNoToast(_ id: ActionID) {
        let services = Self.services()
        var loud: [String] = []
        let previous = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { loud.append(reason) }
            previous?(reason, quiet)
        }
        defer { services.registry.refusalObserver = previous }
        let shown = services.refusalHUD.shownCount
        _ = services.registry.perform(id, invocation: Self.noChatRun())
        #expect(loud.isEmpty, "\(id) asked for the refusal toast: \(loud)")
        #expect(services.refusalHUD.shownCount == shown, "\(id) showed \(services.refusalHUD.message ?? "")")
    }

    /// The chat menu's rows are disabled where they cannot run (no chat, not started, remote, no
    /// folder), from the same lookup their run uses.
    @Test(arguments: chatActions.filter { !["agentPane.markUnread", "agentPane.createCheckpoint", "agentPane.setModel"].contains($0) })
    func aChatMenuRowIsDisabledWithNoChat(_ id: ActionID) {
        let services = Self.services()
        #expect(!ActionTargetReasons.canPerform(id, invocation: Self.noChatRun(), in: services.registry), "\(id) is enabled with no chat")
    }

    /// Toggle Dictation (Ctrl-Cmd-V) off a chat or terminal, with nothing dictating, is disabled: the
    /// key does nothing, where it used to toast "Dictation works in agent chats. Focus one first."
    @Test func dictationOffAChatOrTerminalIsDisabledNotRefused() {
        let services = Self.services()
        var refusals: [String] = []
        let previous = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            refusals.append(reason)
            previous?(reason, quiet)
        }
        defer { services.registry.refusalObserver = previous }
        #expect(services.registry.unavailableReason(for: "palette.toggleDictation") != nil, "Dictation is offered with no chat or terminal")
        #expect(!services.registry.perform("palette.toggleDictation", invocation: ActionInvocation(origin: .user)))
        #expect(refusals.isEmpty, "Dictation refused: \(refusals)")
    }

    /// The refusals' table ships in CmuxNextActions' bundle: a Japanese lookup is a translation, not
    /// the English default (AgentChatMenu.xcstrings had no resource rule, so every locale read English).
    @Test func refusalsAreTranslatedInTheActionsBundle() throws {
        let bundle = AgentChatRefusal.bundle
        let japanese = try #require(bundle.url(forResource: "ja", withExtension: "lproj").flatMap(Bundle.init(url:)),
                                    "\(bundle.bundlePath) has no ja.lproj")
        let missing = "\u{0}missing"
        let text = japanese.localizedString(forKey: "refusal.agentChat.noChat", value: missing, table: "AgentChatMenu")
        #expect(text != missing, "refusal.agentChat.noChat is not in \(bundle.bundlePath)")
        #expect(text != "%@ works in agent chats. Focus one first.")
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A started chat with no project folder (an agent-home chat never gives its folder to a
    /// terminal or Finder): Reveal Chat Folder says the chat has no project folder, never that it
    /// "works once the chat has started".
    @Test func aFolderActionOnAStartedChatWithNoFolderSaysSo() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "chat")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "folder-ws"), name: "folder", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "folder-ws"), index: 0)])
        store.apply(snapshot: tree)
        let controller = try #require(services.windows.openWindow(workspaces: ["folder-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        var key: String?
        defer {
            if let key { services.agentTabs.views[key] = nil }
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        let paneController = try #require(content.panes.values.first, "the window never showed the workspace's pane")
        if paneController.currentTabKey == nil { paneController.showSelected() }
        let tabKey = try #require(paneController.currentTabKey, "the pane shows no tab")
        key = tabKey
        // A chat whose session has started, with no folder of its own.
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "started"), source: .bundled(URL(filePath: "/dev/null"))))
        services.agentTabs.views[tabKey] = chat
        try #require(chat.model.terminalFolder == nil)

        let id: ActionID = "agentPane.revealCwdInFinder"
        var invocation = ActionInvocation(origin: .user)
        invocation.keyContext = [.agentPaneFocused]
        invocation.target = ActionTargetRef(kind: .tab, id: tabKey)
        let reason = try #require(services.registry.capturingRefusal {
            _ = services.registry.perform(id, invocation: invocation)
        }, "Reveal Chat Folder ran with no folder")
        #expect(reason != services.registry.reason(.notStarted, for: id), "a started chat was refused as not started")
        #expect(reason != services.registry.reason(.noChat, for: id), "the chat was not found: \(reason)")
        #expect(reason == services.registry.reason(.noFolder, for: id), "\(reason)")
        // The row is disabled on that chat, so the run never got as far as a toast.
        #expect(!ActionTargetReasons.canPerform(id, invocation: invocation, in: services.registry), "Reveal Chat Folder is enabled on a chat with no folder")
    }
}
