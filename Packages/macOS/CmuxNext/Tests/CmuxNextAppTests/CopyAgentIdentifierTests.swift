import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Copy Agent Identifier (cx-s7004), the first slice of cross-session messaging: the palette and
/// an agent chat's menus (its tab, its sidebar row, the chat itself) copy the chat's acpmux
/// session id, the id `acpmux send <id>` and `cmux agent message <id>` take. Tabs that are not a
/// started chat leave the row out.
@MainActor @Suite(.serialized)
struct CopyAgentIdentifierTests {
    static let action: ActionID = "agentChat.copyIdentifier"
    static let session = "0199e2c4-7f3a-7b21-9d4e-5a1b2c3d4e5f"

    /// One pane: a started chat, a new chat with no session yet, and a terminal.
    static func services() -> (AppServices, chat: TabModel, newChat: TabModel, terminal: TabModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "Fix the build", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: session, harness: "claude"))
        var newChat = TabSnapshot(surface: 2, kind: .conversation, title: "New Chat", url: "about:blank")
        newChat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", harness: "claude"))
        let terminal = TabSnapshot(surface: 3, kind: .terminal, title: "zsh", url: "")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, newChat, terminal])])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let tabs = services.machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        func tab(_ surface: SurfaceID) -> TabModel { tabs.first { $0.surface == surface }! }
        return (services, tab(1), tab(2), tab(3))
    }

    static func runs(_ menu: NSMenu) -> [ActionID] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id }
    }

    static func tabMenu(_ tab: TabModel, _ services: AppServices) -> NSMenu {
        PaneController.tabMenu(tab.id, tab: tab, workspaceKind: nil, sameKind: .terminal, registry: services.registry)
    }

    @Test func aChatsTabMenuAndChatMenuOfferItAndOtherTabsDoNot() {
        let (services, chat, newChat, terminal) = Self.services()
        let descriptor = services.registry.descriptors.first { $0.id == Self.action }
        #expect(descriptor?.surfaces.contains(.palette) == true, "the palette lists Copy Agent Identifier")
        // The strip's tab and its sidebar row share this menu.
        #expect(Self.runs(Self.tabMenu(chat, services)).contains(Self.action))
        let chatBody = services.registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: chat.id))
        #expect(Self.runs(chatBody).contains(Self.action), "right-click in the chat offers it")
        #expect(!Self.runs(Self.tabMenu(newChat, services)).contains(Self.action), "a chat with no session yet has no id to copy")
        #expect(!Self.runs(Self.tabMenu(terminal, services)).contains(Self.action))
    }

    @Test func itCopiesTheChatsAcpmuxSessionID() {
        let (services, chat, _, terminal) = Self.services()
        let pasteboard = NSPasteboard.general
        let kept = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let kept { pasteboard.setString(kept, forType: .string) } }
        pasteboard.clearContents()

        #expect(services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.id))))
        #expect(pasteboard.string(forType: .string) == Self.session)

        pasteboard.clearContents()
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: terminal.id)))
        }
        #expect(refusal != nil, "a terminal says why nothing was copied")
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
