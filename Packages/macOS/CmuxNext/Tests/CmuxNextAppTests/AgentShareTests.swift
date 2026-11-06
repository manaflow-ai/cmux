import AppKit
import CmuxNextActions
import CmuxNextRemote
import CmuxNextWakeups
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextNotifications
import CmuxNextTestSupport
import Testing

/// Share Chat with Guest (design chat-multiplayer.md 6): one `agent.share` op behind the palette,
/// the chat tab's menu, `cmux share chat` and its MCP tool, which names a started agent chat and
/// answers the link; list, revoke and kick are its CLI and MCP family.
@MainActor @Suite(.serialized, .closesItsWindows)
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
        // Invite People is the palette's, the CLI's and MCP's; it asks the owner like a link does.
        let invite = try #require(registry.descriptor(for: AgentShareActions.invite))
        #expect(invite.cliName == "share invite" && invite.isPaletteVisible && invite.surfacePlan.mcp?.isOffered == true)
        #expect(invite.waitsForPerson && invite.waitsForResult)
        #expect(invite.arguments.map(\.name) == ["account", "role", "surface", "ttl"])
        // A person's own run with no account opens the Invite People sheet, so none is required.
        #expect(invite.arguments.filter(\.isRequired).isEmpty)
        #expect(invite.surfacePlan.contextMenus.map(\.context) == [.tab])
        for (id, name) in [(AgentShareActions.list, "share list"), (AgentShareActions.revoke, "share revoke"), (AgentShareActions.kick, "share kick"),
                           (AgentShareActions.uninvite, "share uninvite")] {
            let descriptor = try #require(registry.descriptor(for: id))
            #expect(descriptor.cliName == name && descriptor.surfacePlan.mcp?.isOffered == true)
            #expect(!descriptor.isPaletteVisible, "\(id) is the share sheet's, not the palette's")
        }
    }

    @Test func aStartedChatsTabMenuOffersItAndOtherTabsDoNot() {
        let f = Self.fixture()
        for id in [AgentShareActions.share, AgentShareActions.invite] {
            #expect(Self.runs(Self.tabMenu(f.chat, f.services)).contains(id), "\(id)")
            #expect(!Self.runs(Self.tabMenu(f.newChat, f.services)).contains(id), "\(id)")
            #expect(!Self.runs(Self.tabMenu(f.terminal, f.services)).contains(id), "\(id)")
        }
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

    /// Invites go on the chat's invite share: the newest live share of that chat that already has
    /// invitees. A guest link with none (24 hours, one use) is left to the link, so the run makes a
    /// share for invites instead.
    @Test func anInviteGoesOnTheChatsInviteShare() {
        let invitee = AgentSessionShareInvitee(account: "@theo", role: "talk", invitedAt: 1, state: "invited")
        let removed = AgentSessionShareInvitee(account: "a@cmux.com", role: "view", invitedAt: 1, state: "removed")
        let shares = [
            AgentSessionShare(shareId: "link", state: "active", session: Self.session, surface: 1, createdAt: 9),
            AgentSessionShare(shareId: "old", state: "active", session: Self.session, surface: 1, createdAt: 2, invitees: [invitee]),
            AgentSessionShare(shareId: "new", state: "active", session: Self.session, surface: 1, createdAt: 5, invitees: [removed]),
            AgentSessionShare(shareId: "ended", state: "revoked", session: Self.session, surface: 1, createdAt: 8, invitees: [invitee]),
            AgentSessionShare(shareId: "other", state: "active", session: "another-chat", surface: 1, createdAt: 7, invitees: [invitee]),
        ]
        #expect(AgentShareInvites.inviteShare(of: Self.session, in: shares) == "new")
        #expect(AgentShareInvites.inviteShare(of: Self.session, in: [shares[0]]) == nil, "a guest link is not the invite share")
        // Uninvite finds every share of the chat that still invites the account, in any case.
        #expect(AgentShareInvites.sharesInviting(" @Theo ", of: Self.session, in: shares) == ["old", "ended"])
        #expect(AgentShareInvites.sharesInviting("a@cmux.com", of: Self.session, in: shares).isEmpty, "a removed invitee is not invited")
    }

    @Test func aRoleIsViewOrTalkAndTalkByDefault() {
        #expect(AgentShareInvites.role(nil) == "talk")
        #expect(AgentShareInvites.role(" View ") == "view")
        #expect(AgentShareInvites.role("talk") == "talk")
        #expect(AgentShareInvites.role("admin") == nil)
    }

    /// `share list` shows each share's invitees (account, role, state), its invite link and the account a guest joined as.
    @Test func theListShowsInvitees() {
        let share = AgentSessionShare(shareId: "s1", state: "active", session: Self.session, surface: 1, inviteUrl: "https://room.example/i/s1",
                                      guests: [AgentSessionShareGuest(guestId: "g1", name: "Theo", joinedAt: 3, state: "active", account: "@theo", role: "view")],
                                      invitees: [AgentSessionShareInvitee(account: "@theo", role: "view", invitedAt: 2, state: "invited")])
        let listed = AgentShareResults.list(AgentSessionShareList(shares: [share]))
        guard case .array(let shares)? = listed["shares"], case .object(let fields)? = shares.first else {
            Issue.record("list answers its shares"); return
        }
        #expect(fields["invite_url"] == .string("https://room.example/i/s1"))
        #expect(fields["invitees"] == .array([.object(["account": .string("@theo"), "role": .string("view"), "invited_at": .int(2), "state": .string("invited")])]))
        guard case .array(let guests)? = fields["guests"], case .object(let guest)? = guests.first else {
            Issue.record("list answers its guests"); return
        }
        #expect(guest["account"] == .string("@theo") && guest["role"] == .string("view"))
    }

    @Test func anInviteRefusalSaysWhatToDo() {
        let again = AgentShareStrings.failure(DaemonError.command(cmd: "agent-session-share-invite", message: "uninvite it first", code: "share.invited"))
        #expect(again.code == "share.invited" && again.message == AgentShareStrings.alreadyInvited)
        let shape = AgentShareStrings.failure(AgentShareBadAccount())
        #expect(shape.code == "share.bad_request" && shape.message == AgentShareStrings.badAccount)
        let missing = AgentShareStrings.failure(AgentShareNotInvited(account: "@theo"))
        #expect(missing.code == "share.not_invited" && missing.message.contains("@theo"))
        #expect(AgentShareStrings.failure(AgentShareDeclined(invite: true)).message == AgentShareStrings.inviteDeclined)
        #expect(AgentShareStrings.failure(AgentShareDeclined()).message == AgentShareStrings.declined)
    }

    /// The sheet lists every account still invited on a live share of the chat, once (its latest
    /// invite), oldest first, and whether a device of it is in the chat now.
    @Test func theSheetListsWhoIsInvited() {
        let theo = AgentSessionShareInvitee(account: "@theo", role: "view", invitedAt: 2, state: "invited")
        let theoAgain = AgentSessionShareInvitee(account: "@theo", role: "talk", invitedAt: 6, state: "invited")
        let ana = AgentSessionShareInvitee(account: "ana@cmux.com", role: "talk", invitedAt: 4, state: "invited")
        let gone = AgentSessionShareInvitee(account: "gone@cmux.com", role: "talk", invitedAt: 1, state: "removed")
        let shares = [
            AgentSessionShare(shareId: "a", state: "active", session: Self.session, surface: 1,
                              guests: [AgentSessionShareGuest(guestId: "g", name: "Ana", joinedAt: 5, state: "active", account: "ana@cmux.com", role: "talk")],
                              invitees: [theo, gone]),
            AgentSessionShare(shareId: "b", state: "provisioning", session: Self.session, surface: 1, invitees: [theoAgain, ana]),
            AgentSessionShare(shareId: "c", state: "expired", session: Self.session, surface: 1,
                              invitees: [AgentSessionShareInvitee(account: "old@cmux.com", role: "talk", invitedAt: 1, state: "invited")]),
        ]
        #expect(AgentShareInvites.rows(of: Self.session, in: shares) == [
            AgentShareInviteSheetModel.Row(account: "ana@cmux.com", role: "talk", joined: true),
            AgentShareInviteSheetModel.Row(account: "@theo", role: "talk", joined: false),
        ])
        #expect(AgentShareInvites.rows(of: "another-chat", in: shares).isEmpty)
    }

    /// The sheet runs the op's own work: Invite sends the field's account with the role, clears the
    /// field and reads the list again; a refusal stays on the sheet as its status, the field kept.
    /// The sheet is AppKit (no SwiftUI host). Presented the way the overlay host presents it
    /// (detached, then put in a window), it follows the model with no manual redraw: loaded rows
    /// show with their role, typing turns Invite on, and a row's Remove runs the work for that account.
    @Test func theSheetIsAppKitAndFollowsTheModelOnceShown() async throws {
        @MainActor final class Daemon {
            var removed: [String] = []
            var shares = [AgentSessionShare(shareId: "s", state: "active", session: AgentShareTests.session, surface: 1,
                                            invitees: [AgentSessionShareInvitee(account: "@theo", role: "view", invitedAt: 1, state: "invited")])]
        }
        let daemon = Daemon()
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { daemon.shares },
            invite: { _, _ in },
            remove: { account in
                daemon.removed.append(account)
                daemon.shares = []
            }))
        let card = AgentShareInviteCard(model: model, closeImage: NSImage())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        card.removeFromSuperview()
        window.contentView?.addSubview(card)
        defer { card.removeFromSuperview() }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func rows() -> [AgentShareInviteRowView] { all(card).compactMap { $0 as? AgentShareInviteRowView } }
        func settle(until done: () -> Bool) async { for _ in 0..<200 where !done() { await Task.yield() } }
        #expect(!all(card).contains { String(describing: type(of: $0)).contains("NSHostingView") })
        #expect(!card.inviteButton.isEnabled, "Invite is off with an empty field")
        await model.load()
        await settle { rows().count == 1 }
        let shown = try #require(rows().first)
        #expect(shown.account.stringValue == "@theo")
        #expect(shown.detail.stringValue == model.roleTitle("view"))
        model.account = "@ana"
        await settle { card.inviteButton.isEnabled }
        #expect(card.inviteButton.isEnabled)
        shown.removePressed()
        await settle { !daemon.removed.isEmpty && rows().isEmpty }
        #expect(daemon.removed == ["@theo"])
        #expect(rows().isEmpty && !card.empty.isHidden)
    }

    /// An account typed while an invite runs stays in the field.
    @Test func typingDuringAnInviteKeepsTheNewAccount() async {
        @MainActor final class Box { var model: AgentShareInviteSheetModel? }
        let box = Box()
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { [] },
            invite: { _, _ in box.model?.account = "@bo" },
            remove: { _ in }))
        box.model = model
        model.account = "@ana"
        await model.invite()
        #expect(model.account == "@bo")
    }

    @Test func theSheetInvitesAndRemovesThroughTheWork() async {
        @MainActor final class Daemon {
            var shares: [AgentSessionShare] = []
            var calls: [String] = []
            var refuse = false
        }
        let daemon = Daemon()
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { daemon.shares },
            invite: { account, role in
                daemon.calls.append("invite \(account) \(role)")
                if daemon.refuse { throw DaemonError.command(cmd: "agent-session-share-invite", message: "uninvite it first", code: "share.invited") }
                daemon.shares = [AgentSessionShare(shareId: "s", state: "active", session: Self.session, surface: 1,
                                                   invitees: [AgentSessionShareInvitee(account: account, role: role, invitedAt: 1, state: "invited")])]
            },
            remove: { account in
                daemon.calls.append("remove \(account)")
                daemon.shares = []
            }))
        #expect(!model.canInvite, "Invite is off with an empty field")
        model.account = "  @theo "
        model.role = "view"
        #expect(model.canInvite)
        await model.invite()
        #expect(daemon.calls == ["invite @theo view"])
        #expect(model.account.isEmpty && model.status == nil)
        #expect(model.rows == [AgentShareInviteSheetModel.Row(account: "@theo", role: "view", joined: false)])
        daemon.refuse = true
        model.account = "@theo"
        model.role = "talk"
        await model.invite()
        #expect(model.status == AgentShareStrings.alreadyInvited)
        #expect(model.account == "@theo", "a refused invite keeps what was typed")
        await model.remove("@theo")
        #expect(daemon.calls.last == "remove @theo")
        #expect(model.rows.isEmpty && model.status == nil)
    }

    /// The sheet offers the chat's invite link (its invite share's, from the daemon) and Copy Invite
    /// Link puts it on the pasteboard, then reads Copied for a moment in place.
    @Test func theSheetCopiesTheInviteLinkAndSaysCopiedInPlace() async {
        @MainActor final class Pasteboard { var copied: [String] = [] }
        let pasteboard = Pasteboard()
        let link = "https://room.example/i/s"
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { [AgentSessionShare(shareId: "s", state: "active", session: Self.session, surface: 1, inviteUrl: link,
                                       invitees: [AgentSessionShareInvitee(account: "@theo", role: "view", invitedAt: 1, state: "invited")])] },
            invite: { _, _ in },
            remove: { _ in },
            copy: { pasteboard.copied.append($0) }))
        #expect(model.inviteLink == nil, "no link before the shares are read")
        await model.load()
        #expect(model.inviteLink == link)
        model.copiedFor = .milliseconds(20)
        model.copyLink()
        #expect(pasteboard.copied == [link])
        #expect(model.copied)
        for _ in 0..<200 where model.copied { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.copied, "Copied goes back to Copy Invite Link")
        // A chat with only a guest link (no invitees) has no invite link to copy.
        let none = AgentShareInvites.inviteLink(of: Self.session, in: [
            AgentSessionShare(shareId: "g", state: "active", session: Self.session, surface: 1, inviteUrl: "https://room.example/i/g"),
        ])
        #expect(none == nil)
    }

    /// The card's Copy Invite Link is off until the chat has a link, then copies it and reads Copied
    /// in place (no toast).
    @Test func theCardsCopyInviteLinkConfirmsInPlace() async {
        @MainActor final class Pasteboard { var copied: [String] = [] }
        let pasteboard = Pasteboard()
        let link = "https://room.example/i/s"
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { [AgentSessionShare(shareId: "s", state: "active", session: Self.session, surface: 1, inviteUrl: link,
                                       invitees: [AgentSessionShareInvitee(account: "@theo", role: "view", invitedAt: 1, state: "invited")])] },
            invite: { _, _ in },
            remove: { _ in },
            copy: { pasteboard.copied.append($0) }))
        let card = AgentShareInviteCard(model: model, closeImage: NSImage())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        card.removeFromSuperview()
        window.contentView?.addSubview(card)
        defer { card.removeFromSuperview() }
        #expect(!card.copyButton.isEnabled, "no link before anyone is invited")
        await model.load()
        for _ in 0..<200 where !card.copyButton.isEnabled { await Task.yield() }
        #expect(card.copyButton.isEnabled)
        #expect(card.linkLabel.stringValue == link)
        #expect(card.copyButton.button.title == model.copyLinkTitle)
        card.copyPressed()
        for _ in 0..<200 where card.copyButton.button.title != model.copiedTitle { await Task.yield() }
        #expect(card.copyButton.button.title == model.copiedTitle)
        #expect(pasteboard.copied == [link])
    }

    /// Invite and Remove run one after the other, in the order pressed: a Remove pressed while an
    /// Invite of the same account runs waits for it, so the account ends removed.
    @Test func anInviteAndARemoveOfOneAccountRunInTheOrderPressed() async {
        @MainActor final class Daemon {
            var calls: [String] = []
            var release: CheckedContinuation<Void, Never>?
        }
        let daemon = Daemon()
        let model = AgentShareInviteSheetModel(chat: "Fix the build", session: Self.session, work: .init(
            list: { [] },
            invite: { account, _ in
                daemon.calls.append("invite \(account) starts")
                await withCheckedContinuation { daemon.release = $0 }
                daemon.calls.append("invite \(account) ends")
            },
            remove: { account in daemon.calls.append("remove \(account)") }))
        model.account = "@theo"
        let invite = Task { await model.invite() }
        for _ in 0..<200 where daemon.release == nil { await Task.yield() }
        let remove = Task { await model.remove("@theo") }
        for _ in 0..<50 { await Task.yield() }
        #expect(daemon.calls == ["invite @theo starts"], "the Remove waits for the Invite")
        daemon.release?.resume()
        await invite.value
        await remove.value
        #expect(daemon.calls == ["invite @theo starts", "invite @theo ends", "remove @theo"])
    }

    /// Invite People… with no account: the owner's own run opens the sheet and makes nothing; an
    /// agent's or script's run must name the account.
    @Test func invitePeopleWithNoAccountOpensTheSheetForTheOwnerOnly() {
        @MainActor final class Host: AgentShareHost {
            let services: AppServices
            var shown: [AgentShareInviteSheetModel] = []
            init(_ services: AppServices) { self.services = services }
            func shareTab(surface: SurfaceID) -> TabModel? { services.shareTab(surface: surface) }
            func shareTab(id: String) -> TabModel? { services.shareTab(id: id) }
            func shareTabID(showing session: String) -> String? { nil }
            var shareFocusedTabID: String? { nil }
            func shareConnection(holding tab: TabModel) -> DaemonConnection? { nil }
            func shareIsOnThisMac(_ tab: TabModel) -> Bool { true }
            var shareLocalConnection: DaemonConnection? { nil }
            func shareOwnerToken(api: URL?) async -> String? { nil }
            func shareCopy(_ text: String) {}
            func shareNotice(_ message: String) {}
            func shareShowInvites(_ model: AgentShareInviteSheetModel) { shown.append(model) }
        }
        let f = Self.fixture()
        let host = Host(f.services)
        let registry = ActionRegistry.standard()
        AgentShareActions(host: host).bind(into: registry)
        let mine = registry.capturingTypedRefusal {
            _ = registry.perform(AgentShareActions.invite, invocation: ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: .user))
        }
        #expect(mine == nil, "the owner's own Invite People… was refused: \(mine?.reason ?? "")")
        #expect(host.shown.map(\.chat) == ["Fix the build"])
        var agent = ActionInvocation(target: nil, arguments: ["surface": .int(1)], origin: .mcp)
        agent.viaControlSocket = true
        let refusal = registry.capturingTypedRefusal { _ = registry.perform(AgentShareActions.invite, invocation: agent) }
        #expect(refusal?.reason == AgentShareStrings.needsAccount)
        #expect(host.shown.count == 1, "an agent's run opened the owner's sheet")
    }
}
