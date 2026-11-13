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
    /// The conversation shown under To: (``existing(_:carrying:)``).
    private weak var embedded: EmbeddedConversation?
    /// The sheet is up (false once it went away, by a send or the X).
    private var isUp = false
    /// The presenter lives as long as its sheet is up.
    private static var current: HomeNewMessage?

    init(context: Context) {
        self.context = context
        // The Cloud's own id for this account (a creator joins its group as itself).
        directory = HomeNewMessageDirectory(snapshot: context.snapshot(), cloud: context.sources.account,
                                            me: context.sources.cloudUserID)
        let feed = context.feed, sources = context.sources
        // A first message to a Chief opens its conversation first: a refusal shows under To: and
        // the text stays (the Mac's draft send path), never lost after the sheet goes.
        directory.prepare = { entry in
            switch entry.kind {
            case let .macChief(mac):
                _ = try await feed.session(for: mac)
            case let .cloudChief(agent, conversation):
                guard sources.cloudConversation(CloudConversationRoute(conversationID: conversation, title: entry.contact.name,
                                                                       chief: agent)) != nil else {
                    throw HomeNewMessageDirectory.refusal(String(localized: "Sign in to message people from your iPhone."))
                }
            case .chief, .teammate, .agentTab, .address:
                break
            }
        }
    }

    /// Opens New Message over the frontmost screen; `prefill` is a forwarded draft.
    @discardableResult
    func present(forwarding draft: ConversationForwardDraft? = nil) -> Bool {
        guard let presenter = ChiefComposer.topController() else { return false }
        let compose = ConversationComposeViewController(directory: directory)
        compose.onOpenConversation = { [weak self] creation, message in self?.opened(creation, message: message) }
        compose.onAction = { [weak self] action in self?.run(action) }
        compose.existingConversation = { [weak self] recipients, carrying in self?.existing(recipients, carrying: carrying) }
        compose.onDismiss = { [weak self] in self?.sheetWentAway() }
        sheet = compose
        isUp = true
        Self.current = self
        #if DEBUG
        ChiefDemoHook.shared.compose = compose
        #endif
        if let draft { compose.setDraft(forwarding: draft) }
        let sheetController = compose.makeSheet()
        // Messages grows New Message out of its compose button (the iOS 27.0 reference's present
        // and dismiss): the zoom transition from Home's compose button when it is on screen.
        if draft == nil, let window = presenter.view.window, let button = Self.composeButton(in: window) {
            sheetController.preferredTransition = .zoom { [weak button] _ in button }
        }
        presenter.present(sheetController, animated: true)
        loadTeam()
        return true
    }

    /// Builds New Message's views once, off screen, while Home is idle: the first sheet then
    /// skips the one-time costs (symbol binding, class setup) that otherwise land in the tap's
    /// frame. Once per process.
    static func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        let compose = ConversationComposeViewController(directory: HomeNewMessageDirectory(
            snapshot: HomeRecipientSnapshot(chiefs: [], team: [], agentTabs: [], teamName: nil, canCreateChief: false,
                                            canInvite: false, openCloudChiefAgent: nil),
            cloud: nil, me: nil))
        compose.loadViewIfNeeded()
        compose.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        compose.view.layoutIfNeeded()
    }

    private static var prewarmed = false

    /// Home's compose button as a view: its identifier, else the navigation bar control
    /// labeled New Message (SwiftUI may keep the identifier on the accessibility element only).
    static func composeButton(in window: UIWindow) -> UIView? {
        if let view = window.firstSubview(where: { $0.accessibilityIdentifier == "home.compose" && !$0.isHidden }) { return view }
        let label = String(localized: "New Message")
        let bar = window.firstSubview { ($0 as? UINavigationBar)?.isHidden == false }
        return bar?.firstSubview { view in
            (view is UIControl || view.accessibilityTraits.contains(.button)) && view.accessibilityLabel == label
        }
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
        // The active team, as the Mac reads it (`HomeDirectory.readTeamMembers`): named by the Cloud's
        // team id; the personal space reads the personal team (just this account, so Invite shows).
        let team = context.store.activeTeam.flatMap { context.sources.cloudTeamID(stackTeamID: $0.id) }
        // task-owner: one team read for this sheet; ends with its reply
        Task { [weak self] in
            // As the Mac: listing the teams first lets the Cloud sync a team it has not mirrored yet.
            if team != nil { _ = try? await account.read("user.teams.list") }
            guard let data = try? await account.read("team.members.list", params: ["limit": 200], team: team) else {
                // Unread (offline, refused): no Team section rather than a wrong "nobody else" Invite row.
                guard let self else { return }
                var snapshot = self.context.snapshot()
                snapshot.teamUnread = true
                self.apply(snapshot)
                return
            }
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
        // Photos stay on the blank page, whose first send carries them (a conversation's own box takes text only).
        guard carrying.images.isEmpty else { return nil }
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
            // task-owner: opens the conversation's channel; the kept session goes live in place, and a
            // Chief this phone kept nothing of shows once its channel answers
            Task { [feed = context.feed, weak sheet] in
                guard (try? await feed.session(for: mac)) != nil else { return }
                sheet?.reloadExistingConversation()
            }
            route = .mac(mac)
        case .teammate, .agentTab, .address:
            return nil
        }
        guard let session else { return nil }
        // Another screen draws that conversation (Forward from inside it, or it sits under Home's
        // top screen): a second one would take its updates, so the blank page sends there instead.
        // A screen that has left (its owner is gone) does not count: its leftover observer is replaced.
        guard !session.store.hasLivePrimaryOwner else { return nil }
        let view = EmbeddedConversation(session: session, keyboard: sheet?.keyboard, carrying: carrying.text)
        // A message sent there (a new row of mine, not an older one's progress): New Message is
        // done, and the conversation opens on Home.
        let store = session.store
        view.sentToken = store.addObserver { [weak self, weak view, weak store] change in
            // A row this phone just sent (pending, no seq yet): not my message arriving from another device.
            guard let view, let store, !view.sent, case let .live(inserted, true) = change,
                  inserted.contains(where: { store.message(rowID: $0).map { $0.seq == nil && $0.delivery == .sending } ?? false })
            else { return }
            view.sent = true
            self?.finish(route)
        }
        embedded = view
        return view
    }

    private func finish(_ route: HomeConversationRoute) {
        dismissSheet { [context] in context.open(route) }
    }

    /// The sheet went away: the embedded conversation gives its store back before Home's next
    /// screen over it takes it, and the presenter is let go.
    private func sheetWentAway() {
        isUp = false
        embedded?.release()
        Self.current = nil
    }

    // MARK: The first send

    private func opened(_ creation: ConversationCreation, message: ConversationComposeMessage) {
        // Closed while the first send was on its way: nothing opens and nothing sends.
        guard isUp else { return }
        let id = creation.info.id
        if id.hasPrefix(HomeNewMessageDirectory.cloudConversationPrefix) {
            let cloud = CloudConversationRoute(conversationID: String(id.dropFirst(HomeNewMessageDirectory.cloudConversationPrefix.count)),
                                               title: creation.info.title, chief: nil)
            let session = context.sources.cloudConversation(cloud)
            dismissSheet { [context] in
                context.open(.cloud(cloud))
                // People, not a Chief: no Chief alert permission prompt.
                session?.send(message, asksForAlerts: false)
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
                // The channel opened before the sheet went (``HomeNewMessageDirectory/prepare``): this answers at once.
                // task-owner: the opened conversation's session, then the first message; ends with the send
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
            sheetWentAway()
            then()
            return
        }
        // The sheet's viewDidDisappear (``sheetWentAway``) runs before this completion.
        presenting.dismiss(animated: true, completion: then)
    }
}

/// A Chief's conversation under New Message's To: (the Mac's `HomeHostView` in its New Message
/// page): the transcript and its own message box, without its header (To: names it). It is not
/// Home's Chief screen: it never counts as the Chief on screen (alerts, read state), and it gives
/// the store back when the sheet goes, before Home's screen for that Chief takes it.
@MainActor
final class EmbeddedConversation: UIViewController, ConversationComposeEmbeddable {
    let conversation: ConversationViewController
    let session: ChiefSession
    var sentToken: Int?
    var sent = false
    private let carrying: String

    init(session: ChiefSession, keyboard: MobileKeyboardFrameTracker?, carrying: String) {
        self.session = session
        self.carrying = carrying
        conversation = ConversationViewController(store: session.store, options: .chief, keyboard: keyboard)
        // New Message keeps its title and X.
        conversation.hidesNavigationBar = false
        conversation.showsHeader = false
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var composeHeaderHeight: CGFloat { conversation.composeHeaderHeight }
    var composeDraftText: String { conversation.composeDraftText }
    func composeEmbed(topInset: CGFloat) -> UIScrollView? { conversation.composeEmbed(topInset: topInset) }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A child screen gets no system margins of its own: the bubbles take the sheet's, as on
        // Home's Chief screen (they sat on the edges).
        let margin = max(16, parent?.systemMinimumLayoutMargins.leading ?? 16)
        conversation.viewRespectsSystemMinimumLayoutMargins = false
        conversation.view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
        addChild(conversation)
        conversation.view.frame = view.bounds
        conversation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(conversation.view)
        conversation.didMove(toParent: self)
        // What was typed in the sheet moves into this conversation's box, focused.
        if !carrying.isEmpty, let field = conversation.view.firstSubview(where: { $0.accessibilityIdentifier == "conversation.composer.text" }) as? UITextView {
            field.text = carrying
            field.delegate?.textViewDidChange?(field)
            field.becomeFirstResponder()
        }
    }

    /// Removed from under To: (its token went): it gives the store back at once, so the next
    /// pick of the same Chief can show it again.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { release() }
    }

    /// Stops watching and hands the store's updates back.
    func release() {
        if let sentToken { session.store.removeObserver(sentToken) }
        sentToken = nil
        conversation.releaseStore()
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
