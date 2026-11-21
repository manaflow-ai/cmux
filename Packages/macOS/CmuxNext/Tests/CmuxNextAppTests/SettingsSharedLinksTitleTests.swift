import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// Settings > Privacy and Security > Shared Links names each shared chat as its tab does (Leo,
/// 2026-11-07, on two rows titled about:blank: "the manage links is just about blank"). The rows
/// read the chat's record title, which for an agent chat is the page address `about:blank`.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SettingsSharedLinksTitleTests {
    static let session = "0199e2c4-7f3a-7b21-9d4e-5a1b2c3d4e60"

    /// One pane with an agent chat whose record title is the blank page's address (surface 1) and a
    /// terminal (surface 2).
    static func services() -> (AppServices, chat: TabModel, terminal: TabModel) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: session, harness: "claude"))
        let terminal = TabSnapshot(surface: 2, kind: .pty, title: "zsh", url: "")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, terminal])])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "chat", screens: [screen])]))
        let tabs = services.machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        return (services, tabs.first { $0.surface == 1 }!, tabs.first { $0.surface == 2 }!)
    }

    @Test func aSharedChatIsNamedAsItsTabIsNeverByItsPageAddress() {
        let (services, chat, _) = Self.services()
        #expect(chat.titleText == "about:blank", "the fixture's record carries the page address")
        let title = services.shareTitle(of: chat)
        #expect(title != "about:blank")
        #expect(title == TabTitleResolver(services: services).title(chat))
    }

    @Test func theChatTabIsFoundOnItsStoredSurfaceWhenNoTabNamesItsSession() {
        let (services, chat, terminal) = Self.services()
        #expect(services.shareChatTab(session: nil, surface: SurfaceID(rawValue: 1)) === chat)
        #expect(services.shareChatTab(session: "no-such-session", surface: SurfaceID(rawValue: 2)) === terminal)
    }
}
