import AppKit
import CmuxNextActions
import CmuxNextRemote
import CmuxNextWakeups
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
import Testing

/// Share Chat with Guest (design chat-multiplayer.md 6): one `agent.share` op behind the palette,
/// the chat tab's menu, `cmux share chat` and its MCP tool, which names a started agent chat and
/// answers the link; list, revoke and kick are its CLI and MCP family.
@MainActor @Suite(.serialized)
struct AgentShareTests {
    static let session = "0199e2c4-7f3a-7b21-9d4e-5a1b2c3d4e5f"

    struct Fixture {
        let services: AppServices
        let chat: TabModel, newChat: TabModel, terminal: TabModel
    }

    /// One pane with a started chat (surface 1), a new chat with no session (2) and a terminal (3).
    static func fixture() -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "Fix the build", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", session: session, harness: "claude"))
        var newChat = TabSnapshot(surface: 2, kind: .conversation, title: "New Chat", url: "about:blank")
        newChat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "local", harness: "claude"))
        let terminal = TabSnapshot(surface: 3, kind: .pty, title: "zsh", url: "")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, newChat, terminal])])
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "chat", screens: [screen])]))
        let tabs = services.machines.local.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        func tab(_ surface: SurfaceID) -> TabModel { tabs.first { $0.surface == surface }! }
        return Fixture(services: services, chat: tab(1), newChat: tab(2), terminal: tab(3))
    }

    static func runs(_ menu: NSMenu) -> [ActionID] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items).compactMap { ActionRegistry.menuRun(of: $0)?.id }
    }

    static func tabMenu(_ tab: TabModel, _ services: AppServices) -> NSMenu {
        PaneController.tabMenu(tab.id, tab: tab, keepsTab: false, sameKind: .terminal, registry: services.registry)
    }

    @Test func everySurfaceIsDeclaredOnTheOneOp() throws {
        let registry = ActionRegistry.standard()
        let share = try #require(registry.descriptor(for: AgentShareActions.share))
        #expect(share.cliName == "share chat")
        #expect(share.surfacePlan.palette.isOffered && share.surfacePlan.cli?.isOffered == true)
        #expect(share.surfacePlan.mcp?.isOffered == true)
        #expect(share.surfacePlan.contextMenus.map(\.context) == [.tab])
        #expect(share.defaultShortcut == nil)
        for (id, name) in [(AgentShareActions.list, "share list"), (AgentShareActions.revoke, "share revoke"), (AgentShareActions.kick, "share kick")] {
            let descriptor = try #require(registry.descriptor(for: id))
            #expect(descriptor.cliName == name && descriptor.surfacePlan.mcp?.isOffered == true)
            #expect(!descriptor.isPaletteVisible, "\(id) is the share sheet's, not the palette's")
        }
    }

    @Test func aStartedChatsTabMenuOffersItAndOtherTabsDoNot() {
        let f = Self.fixture()
        #expect(Self.runs(Self.tabMenu(f.chat, f.services)).contains(AgentShareActions.share))
        #expect(!Self.runs(Self.tabMenu(f.newChat, f.services)).contains(AgentShareActions.share))
        #expect(!Self.runs(Self.tabMenu(f.terminal, f.services)).contains(AgentShareActions.share))
    }

    @Test func aRunNamesTheChatBySurfaceOrTarget() {
        let f = Self.fixture()
        let host = f.services
        var bySurface = ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: .cli)
        guard case .success(let chat) = AgentShareActions.chat(bySurface, host: host) else {
            Issue.record("surface 1 is the started chat"); return
        }
        #expect(chat.surface == 1)
        let byTarget = ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.chat.id), arguments: [:], origin: .cli)
        if case .success(let chat) = AgentShareActions.chat(byTarget, host: host) { #expect(chat.surface == 1) } else {
            Issue.record("the chat's tab target names it")
        }
        for surface in [2, 3] {
            bySurface.arguments["surface"] = .int(surface)
            guard case .failure(let refusal) = AgentShareActions.chat(bySurface, host: host) else {
                Issue.record("surface \(surface) is not a started chat"); continue
            }
            #expect(refusal == AgentShareRefusal(reason: AgentShareStrings.notAChat))
        }
        bySurface.arguments["surface"] = .int(99)
        guard case .failure(let missing) = AgentShareActions.chat(bySurface, host: host) else {
            Issue.record("surface 99 names nothing"); return
        }
        #expect(missing.isNotFound)
    }

    /// The owner's token goes only to this Mac's daemon, and list reads only this Mac's shares: a chat
    /// on another machine is named, but marked not local, so share and list refuse it.
    @Test func aChatOnAnotherMachineIsNotThisMacs() throws {
        let f = Self.fixture()
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-agent-share-remote-unused")),
                                    environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        f.services.machines.add(ssh)
        // Its own surface, so its tab id is not the local chat's (an id both machines hold resolves to
        // the first machine that has it, which is a different question).
        var remote = TabSnapshot(surface: 7, kind: .conversation, title: "Remote chat", url: "about:blank")
        remote.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "lab", session: Self.session, harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [remote])])
        ssh.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "remote", screens: [screen])]))
        let remoteTab = try #require(ssh.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(!f.services.shareIsOnThisMac(remoteTab))
        #expect(f.services.shareIsOnThisMac(f.chat))
        let byTarget = ActionInvocation(target: ActionTargetRef(kind: .tab, id: remoteTab.id), arguments: [:], origin: .cli)
        #expect(remoteTab.id != f.chat.id)
        guard case .success(let remoteChat) = AgentShareActions.chat(byTarget, host: f.services) else {
            Issue.record("the remote chat's tab target names it"); return
        }
        #expect(remoteChat.surface == remoteTab.surface.rawValue)
        #expect(!remoteChat.isLocal, "another machine's chat counted as this Mac's")
        let local = ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.chat.id), arguments: [:], origin: .cli)
        guard case .success(let chat) = AgentShareActions.chat(local, host: f.services) else {
            Issue.record("the local chat's tab target names it"); return
        }
        #expect(chat.isLocal)
    }

    /// A surface or target that names nothing answers `not_found`, not `unavailable`.
    @Test func aMissingChatAnswersNotFound() {
        let f = Self.fixture()
        let registry = f.services.registry
        for (id, arguments) in [(AgentShareActions.share, ["surface": ActionValue.int(99)]), (AgentShareActions.list, ["surface": ActionValue.int(99)])] {
            let refusal = registry.capturingTypedRefusal {
                _ = registry.perform(id, invocation: ActionInvocation(target: nil, arguments: arguments, origin: .cli))
            }
            #expect(refusal?.isNotFound == true, "\(id) on a missing surface did not answer not_found")
        }
        let notAChat = registry.capturingTypedRefusal {
            _ = registry.perform(AgentShareActions.share, invocation: ActionInvocation(target: nil, arguments: ["surface": .int(3)], origin: .cli))
        }
        #expect(notAChat?.isNotFound == false, "a terminal is not a missing target")
    }

    /// A malformed or doubled selector, or a target that is not a tab, is refused: it never falls
    /// back to the focused chat or the caller's.
    @Test func aSelectorThatCannotNameOneChatIsRefused() {
        let f = Self.fixture()
        let host = f.services
        let cases: [(ActionInvocation, String)] = [
            (ActionInvocation(target: nil, arguments: ["surface": .string("abc")], origin: .cli), AgentShareStrings.badSurface),
            (ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.chat.id), arguments: ["surface": .int(1)], origin: .cli),
             AgentShareStrings.surfaceAndTarget),
            (ActionInvocation(target: ActionTargetRef(kind: .pane, id: "1"), arguments: [:], origin: .cli), AgentShareStrings.notAChat),
            (ActionInvocation(target: ActionTargetRef(kind: .workspace, id: "1"), arguments: [:], origin: .cli), AgentShareStrings.notAChat),
        ]
        for (invocation, reason) in cases {
            guard case .failure(let refusal) = AgentShareActions.chat(invocation, host: host) else {
                Issue.record("\(invocation) named a chat"); continue
            }
            #expect(refusal.reason == reason)
        }
        let byTarget = ActionInvocation(target: ActionTargetRef(kind: .tab, id: f.chat.id), arguments: [:], origin: .cli)
        guard case .success(let chat) = AgentShareActions.chat(byTarget, host: host) else {
            Issue.record("the chat's tab target names it"); return
        }
        #expect(chat.session == Self.session, "the share does not pin the session it named")
    }

    /// An agent's run whose own chat is not found is refused; it never falls back to the focused chat.
    @Test func anAgentWhoseChatIsGoneSharesNothing() {
        let f = Self.fixture()
        var invocation = ActionInvocation(target: nil, arguments: [:], origin: .cli)
        invocation.callerAgentSession = "0199e2c4-0000-7000-8000-00000000dead"
        guard case .failure(let refusal) = AgentShareActions.chat(invocation, host: f.services) else {
            Issue.record("an agent whose chat is gone named another chat"); return
        }
        #expect(refusal.isNotFound)
    }

    @Test func ttlTakesSecondsOrAUnitWithinOneMinuteToSevenDays() throws {
        #expect(try AgentShareArguments.ttl(nil) == nil)
        #expect(try AgentShareArguments.ttl(" ") == nil)
        #expect(try AgentShareArguments.ttl("24h") == 86400)
        #expect(try AgentShareArguments.ttl("90m") == 5400)
        #expect(try AgentShareArguments.ttl("7d") == 604_800)
        #expect(try AgentShareArguments.ttl("3600") == 3600)
        #expect(try AgentShareArguments.ttl("60S") == 60)
        for bad in ["59", "8d", "h", "-1h", "1.5h", "99999999999999999999d"] {
            #expect(throws: AgentShareArguments.BadTTL.self, "\(bad)") { try AgentShareArguments.ttl(bad) }
        }
    }

    @Test func aDaemonRefusalKeepsItsCodeWithAPersonsSentence() {
        let signIn = AgentShareStrings.failure(DaemonError.command(cmd: "agent-session-share-create", message: "needs owner_token", code: "share.needs_sign_in"))
        #expect(signIn.code == "share.needs_sign_in")
        #expect(signIn.message == AgentShareStrings.reason("share.needs_sign_in"))
        let other = AgentShareStrings.failure(DaemonError.command(cmd: "agent-session-share-create", message: "the share is not open", code: "share.closed"))
        #expect(other.code == "share.closed" && other.message == "the share is not open")
        #expect(AgentShareStrings.failure(DaemonError.notConnected).code == nil)
        #expect(!AgentShareStrings.failure(DaemonError.notConnected).mayHaveApplied)
        // A create with no answer in time may still have made the link: the caller must not just retry.
        let late = AgentShareStrings.failure(DaemonError.timedOut("agent-session-share-create"))
        #expect(late.mayHaveApplied)
        #expect(late.message == AgentShareStrings.timedOut)
    }

    @Test func theAnswersCarryTheLinkButNeverItsSecretAlone() {
        let created = AgentShareResults.created(AgentSessionShareCreated(shareId: "s1", url: "https://room/g/s1#k", expiresAt: 1_700_000_000_000,
                                                                         session: Self.session, surface: 1, usesLeft: 1))
        #expect(created["url"] == .string("https://room/g/s1#k"))
        #expect(created["expires_at"] == .int(1_700_000_000_000))
        #expect(created["secret"] == nil)
        let roomless = AgentShareResults.created(AgentSessionShareCreated(shareId: "s1", url: nil, expiresAt: 1, session: Self.session, surface: 1, usesLeft: 1))
        #expect(roomless["url"] == .null)
        #expect(AgentShareResults.ended(.object(["share_id": .string("s1"), "state": .string("revoked")]))
            == ["share_id": .string("s1"), "state": .string("revoked")])
    }
}
