import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Every way a person opens a terminal or browser from a Cloud chat goes to the chat's Cloud machine, through the one
/// rule (``CloudChatFocus``) and the chat header's route (cmux#57249). User, 2026-11-25: "if we click these buttons or are
/// focused on a cloud chat it should go into the cloud terminal and cloud browser".
@MainActor @Suite(.serialized)
struct CloudChatFocusPathsTests {
    struct Opened: Equatable { var kind: RightColumnPlacement.Kind; var machine: String; var key: String; var typing: String? }

    /// This Mac's pane showing Mac tab `mac-1`, which shows Cloud chat `chat-1` of a Cloud machine in place; every open on
    /// the machine is recorded in `opened` instead of reaching it.
    @MainActor final class Fixture {
        let services: AppServices, session: CloudMachineSession, pane: PaneModel
        var opened: [Opened] = []
        init() throws {
            services = MachineIconTests.services()
            AppActions.bind(services)
            session = MachineIconTests.cloudMachine(services, id: "vm-focus-\(UUID().uuidString.prefix(8))")
            var mac = TabSnapshot(surface: SurfaceID(rawValue: 1), tabResourceID: "mac-1", kind: .conversation, cwd: "/Users/me")
            mac.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "", session: "s-mac", harness: "claude"))
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [mac])])
            let local = services.machines.local
            local.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: "ws-mac", name: "Mac", screens: [screen])]))
            local.store.noteHandshake(DaemonIdentity(capabilities: [DaemonCapability.frontendBrowserTabs.rawValue], generation: "focus-fixture"))
            pane = try #require(local.store.workspaces.first?.screens.first?.panes.first)
            services.agentTabs.frontedChats.front(AgentTabKey(machine: local.machineID, key: "mac-1"),
                                                  with: CloudFrontedChats.Front(machine: session.machineID, key: "chat-1", workspace: "ws-chat"))
            services.agentTabs.frontedChats.openToolOverride = { [unowned self] kind, chat, _, typing in
                opened.append(Opened(kind: kind, machine: chat.machine, key: chat.key, typing: typing)); return true
            }
        }
        func on(_ kind: RightColumnPlacement.Kind, typing: String? = nil) -> [Opened] { [Opened(kind: kind, machine: session.machineID, key: "chat-1", typing: typing)] }
        func perform(_ id: ActionID, origin: ActionOrigin = .user) {
            _ = services.registry.capturingRefusal { _ = services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), origin: origin)) }
        }
    }

    /// New Terminal (`newSurface`): the pane toolbar's >_ button, its key, the palette and the menu bar.
    @Test func newTerminalOpensOnTheChatsMachine() throws {
        let f = try Fixture()
        f.perform("newSurface")
        #expect(f.opened == f.on(.terminal))
    }

    /// New Browser (`openBrowser`): the pane toolbar's globe, Cmd-Shift-L, the palette and the menu bar.
    @Test func newBrowserOpensTheChatsMachineDesktop() throws {
        let f = try Fixture()
        f.perform("openBrowser")
        #expect(f.opened == f.on(.browser))
    }

    /// The pane toolbar's buttons themselves (the screenshot's >_ and globe) run those actions on the pane.
    @Test func thePaneToolbarsButtonsOpenOnTheChatsMachine() throws {
        let f = try Fixture()
        let toolbar = PaneToolbar(registry: { [services = f.services] in services.registry }, paneTarget: ActionTargetRef(kind: .pane, id: f.pane.id),
                                  machineID: { [services = f.services] in services.machines.local.machineID })
        _ = f.services.registry.capturingRefusal {
            toolbar.view.onPerform?("newSurface")
            toolbar.view.onPerform?("openBrowser")
        }
        #expect(f.opened == f.on(.terminal) + f.on(.browser))
    }

    /// Split Right, Split Down (Cmd-D, Cmd-Shift-D), Split Left and Split Up: a terminal on the machine, never a split here.
    @Test(arguments: ["splitRight", "splitDown", "splitLeft", "splitUp"])
    func splitsOpenATerminalOnTheChatsMachine(_ id: String) throws {
        let f = try Fixture()
        f.perform(ActionID(rawValue: id))
        #expect(f.opened == f.on(.terminal))
    }

    /// Split Browser Right / Down: the machine's desktop.
    @Test(arguments: ["splitBrowserRight", "splitBrowserDown"])
    func splitBrowsersOpenTheChatsMachineDesktop(_ id: String) throws {
        let f = try Fixture()
        f.perform(ActionID(rawValue: id))
        #expect(f.opened == f.on(.browser))
    }

    /// The New Tab page opened from the chat: its Terminal pick runs or types its text on the machine, its blank Browser
    /// pick opens the machine's desktop; a pick with an address or an agent pick opens as before.
    @Test func theNewTabPagesPicksOpenOnTheChatsMachine() throws {
        let f = try Fixture()
        let chat = AgentTabKey(machine: f.session.machineID, key: "chat-1")
        var closed = 0
        func pick(_ kind: AgentPaneTabKind, _ text: String, run: Bool = true, keep: Bool = false, picked: Bool = true) -> Bool {
            NewTabPage.opensOnCloud(AgentPaneOpenTab(kind: kind, text: text, run: run, keep: keep, picked: picked), chat: chat, services: f.services, close: { closed += 1 })
        }
        #expect(pick(.terminal, "ls"))
        #expect(pick(.terminal, "git st", run: false))
        #expect(pick(.browser, ""))
        #expect(!pick(.browser, "example.com"), "an address opens here: the desktop takes none")
        #expect(!pick(.agent, "hi"))
        #expect(!pick(.terminal, "claude /login", keep: true), "the page's harness Sign In acts on this Mac's harness")
        #expect(!pick(.terminal, "npm i -g @openai/codex", picked: false), "so do its Install, Log In and Reauthenticate")
        #expect(!pick(.terminal, "echo cmux-vnc://pair?room=r"), "a pairing link is refused, never typed on the machine")
        #expect(f.opened == f.on(.terminal, typing: "ls\n") + f.on(.terminal, typing: "git st") + f.on(.browser))
        #expect(closed == 3, "the page closes once its pick opened on the machine")
    }

    /// A native New Tab page opened from the Cloud chat counts as it: its palette rows' New Terminal and New Browser
    /// (and the pane toolbar's while the page shows) open on the chat's machine; a page from no Cloud chat is unchanged.
    @Test func aNativeNewTabPageFromTheChatOpensItsRowsOnTheChatsMachine() throws {
        let f = try Fixture()
        let page = "local-page:nativeNewTab:\(UUID().uuidString)" // an app-only page, in no daemon's tree
        let chat = AgentTabKey(machine: f.session.machineID, key: "chat-1")
        #expect(CloudFrontedChats.cloudChat(showingPage: page, services: f.services) == nil)
        f.services.agentTabs.frontedChats.pageOrigins[page] = chat
        #expect(CloudFrontedChats.cloudChat(showingPage: page, services: f.services) == chat)
        #expect(CloudFrontedChats.cloudChat(showingPage: page, byPerson: false, services: f.services) == nil, "a script keeps its target")
        #expect(CloudFrontedChats.cloudChat(showingPage: page, namesPlace: true, services: f.services) == nil)
    }

    /// A script's open (CLI, MCP) keeps its target; a pane showing this Mac's own chat opens here as before.
    @Test func scriptsAndThisMacsChatsAreUnchanged() throws {
        let f = try Fixture()
        f.perform("newSurface", origin: .cli)
        #expect(f.opened.isEmpty)
        f.services.agentTabs.frontedChats.gone(AgentTabKey(machine: f.services.machines.local.machineID, key: "mac-1"))
        f.perform("newSurface")
        f.perform("splitDown")
        #expect(f.opened.isEmpty)
    }
}
