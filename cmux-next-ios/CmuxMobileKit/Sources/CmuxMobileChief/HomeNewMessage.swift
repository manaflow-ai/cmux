#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileSupport
import Foundation
import UIKit

/// Home's compose button and Forward: New Message as the Mac has it
/// (`HomeNewMessageView`, user direction 2026-11-11: "full parity with cmux
/// next mac"), drawn as Messages' New Message sheet. Before anything is typed
/// the list under To: shows the Chiefs (main first, tagged where each runs)
/// with New Chief, then the team (or Invite). Typing finds people, agent
/// chats and addresses. When the chosen people already have a conversation it
/// shows under To:, with its own message box; otherwise the first send makes
/// it (one teammate: `dm.open`; several: a Cloud group) and opens it on Home's
/// stack.
@MainActor
public final class HomeNewMessage {
    /// What Home hands New Message.
    public struct Context {
        let store: AppStore
        let sources: ChiefSources
        let feed: MacHomeFeed
        /// Pushes a conversation on Home's stack.
        let open: (HomeConversationRoute) -> Void
        /// Home's people as they are now (read again when the team arrives).
        let snapshot: @MainActor () -> HomeRecipientSnapshot
        /// New Chief's name prompt (nil: this account cannot make Chiefs).
        let newChief: (() -> Void)?
        /// Invites `email` to the active team.
        let inviteToTeam: ((String) -> Void)?
    }

    private let context: Context
    private let directory: HomeNewMessageDirectory
    private weak var sheet: ConversationComposeViewController?
    /// The presenter lives as long as its sheet does (the sheet holds it).
    private static var current: HomeNewMessage?

    init(context: Context) {
        self.context = context
        let me = context.sources.activeUserID.map(HomeNewMessageDirectory.participantID)
        directory = HomeNewMessageDirectory(snapshot: context.snapshot(), cloud: context.sources.account, me: me)
    }

    /// Opens New Message over the frontmost screen; `prefill` is a forwarded draft.
    @discardableResult
    func present(forwarding draft: ConversationForwardDraft? = nil) -> Bool {
        guard let presenter = ChiefComposer.topController() else { return false }
        let compose = ConversationComposeViewController(directory: directory)
        compose.onOpenConversation = { [weak self] creation, message in self?.opened(creation, message: message) }
        compose.onAction = { [weak self] action in self?.run(action) }
        compose.existingConversation = { [weak self] recipients, carrying in self?.existing(recipients, carrying: carrying) }
        sheet = compose
        Self.current = self
        #if DEBUG
        ChiefDemoHook.shared.compose = compose
        #endif
        if let draft { compose.setDraft(forwarding: draft) }
        presenter.present(compose.makeSheet(), animated: true)
        loadTeam()
        return true
    }

    // MARK: The team

    /// The active team's members (`team.members.list`), read once per sheet;
    /// the list shows them under "Team" when they arrive.
    private func loadTeam() {
        let me = directory.me
        #if DEBUG
        if context.sources.account == nil, DeveloperOptions.mockContentEnabled {
            var snapshot = context.snapshot()
            snapshot.team = HomeNewMessageDemo.team
            apply(snapshot)
            return
        }
        #endif
        guard let account = context.sources.account else { return }
        // task-owner: one team read for this sheet; ends with its reply
        Task { [weak self] in
            guard let data = try? await account.read("team.members.list", params: ["limit": 200]) else { return }
            guard let self else { return }
            var snapshot = self.context.snapshot()
            snapshot.team = HomeNewMessageDirectory.withLines(HomeNewMessageDirectory.teammates(from: data, excluding: me))
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: HomeRecipientSnapshot) {
        directory.update(snapshot)
        sheet?.session.refreshRows()
    }

    // MARK: Actions under To:

    private func run(_ action: ConversationComposeAction) {
        switch action.id {
        case HomeNewMessageDirectory.newChiefAction.id:
            // The Mac's New Chief row runs `home.newChief`: here its name prompt, on Home.
            dismissSheet { [newChief = context.newChief] in newChief?() }
        case HomeNewMessageDirectory.inviteAction.id:
            // Over New Message, so what was typed stays.
            guard let sheet else { return }
            let share = ChiefInvite.shareSheet()
            share.popoverPresentationController?.sourceView = sheet.view
            sheet.present(share, animated: true)
        default:
            guard action.id.hasPrefix(HomeNewMessageDirectory.inviteToTeamPrefix), let sheet, let team = directory.snapshot.teamName else { return }
            let email = String(action.id.dropFirst(HomeNewMessageDirectory.inviteToTeamPrefix.count))
            // The Mac asks first (its confirmation dialog, prefilled).
            let alert = UIAlertController(title: String(format: String(localized: "Invite to %@"), team),
                                          message: String(format: String(localized: "%1$@ gets an email with a link to join %2$@."), email, team),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Send Invite"), style: .default) { [weak self] _ in
                self?.context.inviteToTeam?(email)
                self?.sheet?.say(nil)
            })
            sheet.present(alert, animated: true)
        }
    }

    // MARK: The conversation the chosen people already have

    /// One Chief chosen: its conversation under To:, live, with its own
    /// message box (what was typed moves into it). A teammate's DM is not
    /// known to the phone before `dm.open`, so it starts on the blank page.
    private func existing(_ recipients: [ConversationRecipient], carrying: ConversationComposeMessage) -> UIViewController? {
        guard recipients.count == 1, let id = recipients[0].contactID, let entry = directory.entry(id: id) else { return nil }
        let session: ChiefSession?
        let route: HomeConversationRoute
        switch entry.kind {
        case let .chief(place):
            session = context.sources.session(for: place)
            route = .chief(place)
        case let .cloudChief(agent, conversation):
            let cloud = CloudConversationRoute(conversationID: conversation, title: entry.contact.name, chief: agent)
            session = context.sources.cloudConversation(cloud)
            route = .cloud(cloud)
        case let .macChief(mac):
            session = context.feed.keptSession(for: mac)
            // task-owner: opens the conversation's channel; the kept session goes live in place
            Task { [feed = context.feed] in _ = try? await feed.session(for: mac) }
            route = .mac(mac)
        case .teammate, .agentTab, .address:
            return nil
        }
        guard let session else { return nil }
        // That conversation is open under New Message (Forward from inside it): its screen owns the
        // store's updates, so the blank page sends there instead of showing a second copy.
        if let id = session.conversationID, ChiefSession.conversationOnScreen == id { return nil }
        if !carrying.text.isEmpty { session.carryComposerText(carrying.text) }
        // The sheet's keyboard tracker: the keyboard is already up, and the message box sits on it.
        let conversation = ConversationViewController(store: session.store, options: .chief, keyboard: sheet?.keyboard)
        // New Message keeps its title and X.
        conversation.hidesNavigationBar = false
        // To: names it: no header of its own (its room stays, slid under To:).
        conversation.showsHeader = false
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        container.focusesComposerOnAppear = !carrying.text.isEmpty
        // A message sent there: New Message is done, and the conversation opens on Home.
        let watch = SentWatch()
        container.sentWatch = watch
        session.store.addObserver { [weak watch, weak self] change in
            guard let watch, !watch.fired, case .live(_, true) = change else { return }
            watch.fired = true
            self?.finish(route)
        }
        return container
    }

    final class SentWatch {
        var fired = false
    }

    private func finish(_ route: HomeConversationRoute) {
        // Never embedded over its own open screen (``existing``), so it always opens on Home.
        dismissSheet { [context] in context.open(route) }
    }

    // MARK: The first send

    private func opened(_ creation: ConversationCreation, message: ConversationComposeMessage) {
        let id = creation.info.id
        if id.hasPrefix(HomeNewMessageDirectory.cloudConversationPrefix) {
            let cloud = CloudConversationRoute(conversationID: String(id.dropFirst(HomeNewMessageDirectory.cloudConversationPrefix.count)),
                                               title: creation.info.title, chief: nil)
            let session = context.sources.cloudConversation(cloud)
            dismissSheet { [context] in
                context.open(.cloud(cloud))
                session?.send(message)
            }
            return
        }
        guard let entry = directory.entry(id: id) else { return }
        dismissSheet { [context] in
            switch entry.kind {
            case let .chief(place):
                let session = context.sources.session(for: place)
                // Forwarded from inside this Chief's own conversation: send there, without a second copy of it.
                if session.conversationID == nil || ChiefSession.conversationOnScreen != session.conversationID {
                    context.open(.chief(place))
                }
                session.send(message)
            case let .cloudChief(agent, conversation):
                let cloud = CloudConversationRoute(conversationID: conversation, title: entry.contact.name, chief: agent)
                context.open(.cloud(cloud))
                context.sources.cloudConversation(cloud)?.send(message)
            case let .macChief(mac):
                context.open(.mac(mac))
                // task-owner: the conversation's channel, then the first message; ends with the send
                Task { [feed = context.feed] in (try? await feed.session(for: mac))?.send(message) }
            case let .agentTab(destination):
                ChiefComposer.send(message, to: destination, store: context.store, open: context.open)
            case .teammate, .address:
                // Made by the Cloud (`cloud:` ids, above).
                break
            }
        }
    }

    private func dismissSheet(then: @escaping () -> Void) {
        guard let presenting = sheet?.navigationController?.presentingViewController ?? sheet?.presentingViewController else {
            Self.current = nil
            then()
            return
        }
        presenting.dismiss(animated: true) {
            Self.current = nil
            then()
        }
    }
}

#if DEBUG
/// Demo and UI tests (mock content, no Cloud service): a team to list.
@MainActor
enum HomeNewMessageDemo {
    static var team: [HomeRecipientEntry] {
        // The Mac-only demo is a team of one: its list offers Invite instead.
        if CommandLine.arguments.contains("new-message-mac-only") { return [] }
        return [("user_demo_ada", "Ada Lovelace"), ("user_demo_grace", "Grace Hopper"), ("user_demo_alan", "Alan Turing")]
            .map { HomeNewMessageDirectory.teammate(id: $0.0, name: $0.1) }
    }
}
#endif
#endif
