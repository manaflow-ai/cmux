import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// Copy Agent Identifier (cx-s7004), the first slice of cross-session messaging: the palette and
/// an agent chat's menus (its tab, its sidebar row, the chat itself, and the sidebar workspace row
/// that shows its summary) copy the chat's acpmux session id, the id `acpmux send <id>` and
/// `cmux agent message <id>` take. Tabs and workspaces that are not a started chat leave the row out.
@MainActor @Suite(.serialized)
struct CopyAgentIdentifierTests {
    static let action: ActionID = "agentChat.copyIdentifier"
    static let session = "0199e2c4-7f3a-7b21-9d4e-5a1b2c3d4e5f"

    /// What the action copied: the fixture binds it to this recorder, not the general
    /// pasteboard, which a headless test host cannot reach.
    final class Copied { var text: String? }

    struct Fixture {
        let services: AppServices
        let copied: Copied
        let chat: TabModel, newChat: TabModel, terminal: TabModel
        /// The chat's workspace, and one with only a terminal.
        let chatWorkspace: String, terminalWorkspace: String
        /// A workspace no window shows whose pane holds two started chats, the second selected.
        let twoChatsWorkspace: String
    }

    static let secondSession = "0199e2c4-9b10-7c44-8a2e-6f7a8b9c0d1e"

    /// One workspace whose pane has a started chat, a new chat with no session yet and a
    /// terminal, and a second workspace with only a terminal.
    static func fixture() -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let copied = Copied()
        AgentChatIdentifierHandlers.bind(into: services.registry, context: AppActionContext(services: services)) { copied.text = $0 }
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "Fix the build", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: session, harness: "claude"))
        var newChat = TabSnapshot(surface: 2, kind: .conversation, title: "New Chat", url: "about:blank")
        newChat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", harness: "claude"))
        let terminal = TabSnapshot(surface: 3, kind: .pty, title: "zsh", url: "")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, newChat, terminal])])
        let other = ScreenSnapshot(id: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 4, kind: .pty, title: "zsh", url: "")])])
        var first = TabSnapshot(surface: 5, kind: .conversation, title: "Plan", url: "about:blank")
        first.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: "0199e2c4-0000-7000-8000-000000000001", harness: "codex"))
        var second = TabSnapshot(surface: 6, kind: .conversation, title: "Ship", url: "about:blank")
        second.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: secondSession, harness: "claude"))
        let twoChats = ScreenSnapshot(id: 3, layout: .leaf(3), panes: [PaneSnapshot(id: 3, activeTab: 1, tabs: [first, second])])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "chat", screens: [screen]),
            WorkspaceSnapshot(id: 2, key: nil, name: "shell", screens: [other]),
            WorkspaceSnapshot(id: 3, key: nil, name: "two chats", screens: [twoChats]),
        ]))
        let workspaces = services.machines.local.store.workspaces
        let tabs = workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        func tab(_ surface: SurfaceID) -> TabModel { tabs.first { $0.surface == surface }! }
        return Fixture(services: services, copied: copied, chat: tab(1), newChat: tab(2), terminal: tab(3),
                       chatWorkspace: workspaces[0].id, terminalWorkspace: workspaces[1].id,
                       twoChatsWorkspace: workspaces[2].id)
    }

    static func runs(_ menu: NSMenu) -> [ActionID] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id }
    }

    static func tabMenu(_ tab: TabModel, _ services: AppServices) -> NSMenu {
        PaneController.tabMenu(tab.id, tab: tab, keepsTab: false, sameKind: .terminal, registry: services.registry)
    }

    static func workspaceMenu(_ id: String, _ services: AppServices) -> NSMenu {
        services.registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: id))
    }

    @Test func aChatsTabMenuAndChatMenuOfferItAndOtherTabsDoNot() {
        let f = Self.fixture()
        let (services, chat, newChat, terminal) = (f.services, f.chat, f.newChat, f.terminal)
        let descriptor = services.registry.descriptors.first { $0.id == Self.action }
        #expect(descriptor?.surfaces.contains(.palette) == true, "the palette lists Copy Agent Identifier")
        // The strip's tab and its sidebar row share this menu.
        #expect(Self.runs(Self.tabMenu(chat, services)).contains(Self.action))
        let chatBody = services.registry.makeContextMenu(for: .agentChat, target: ActionTargetRef(kind: .tab, id: chat.id))
        #expect(Self.runs(chatBody).contains(Self.action), "right-click in the chat offers it")
        #expect(!Self.runs(Self.tabMenu(newChat, services)).contains(Self.action), "a chat with no session yet has no id to copy")
        #expect(!Self.runs(Self.tabMenu(terminal, services)).contains(Self.action))
    }

    /// The workspace row's menu no longer lists it (Leo 2026-10-23: trim the row menu, keep the
    /// palette); run on a workspace (the palette, CLI) it still copies the chat its summary shows.
    @Test func aWorkspaceShowingAChatsSummaryCopiesThatChat() {
        let f = Self.fixture()
        #expect(!Self.runs(Self.workspaceMenu(f.chatWorkspace, f.services)).contains(Self.action), "the row menu is trimmed")
        #expect(f.services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: f.chatWorkspace))))
        #expect(f.copied.text == Self.session)
    }

    /// The row copies the chat its summary line shows (SidebarMapping), not merely the first
    /// chat: here the pane's selected tab, the second chat, in a workspace no window shows.
    @Test func theWorkspaceRowCopiesTheChatItsSummaryShows() {
        let f = Self.fixture()
        #expect(f.services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: f.twoChatsWorkspace))))
        #expect(f.copied.text == Self.secondSession, "the summary shows the selected chat")
    }

    @Test func itCopiesTheChatsAcpmuxSessionID() {
        let f = Self.fixture()
        let (services, chat, terminal) = (f.services, f.chat, f.terminal)
        #expect(services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.id))))
        #expect(f.copied.text == Self.session)

        f.copied.text = nil
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform(Self.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: terminal.id)))
        }
        #expect(refusal != nil, "a terminal says why nothing was copied")
        #expect(f.copied.text == nil)
    }
}
