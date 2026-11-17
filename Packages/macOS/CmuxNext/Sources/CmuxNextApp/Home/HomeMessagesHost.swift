import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import Foundation
import MessagesLabHome

/// What the Messages page (`webviews/src/pages/home-messages`) asks of the app beyond its menus
/// (``HomeMessagesPageRoute``): the data and the runs of its sheets, its link previews, the header's
/// panel toggles, the chats' colours, and the conversation it shows. Every run is the code the
/// AppKit Home ran (`HomeService`, `HomeGroupActions`, `HomeMessageRequests`, `HomeTeamInviteRun`),
/// so the palette, the CLI and the page change the same things. It keeps no model of its own.
///
/// Calls (each `cmux.home.messages.<op>`; outcomes are `{kind, …}` as sheets/model.ts reads them):
/// - `selected {conversation | null, message?, composing?}`: the page's open conversation (sync
///   actions read it); `composing`: New Message shows, which the default selection leaves alone.
/// - `drafts.load {}` -> `{drafts}`; `drafts.save {conversation, text}`: the composer drafts, kept in
///   HomeStore's draft cache (as the native composer kept them) across reconnects and launches.
/// - `attachments.load {}` -> `{attachments, legacy}`; `attachments.save {conversation, parts, migrated}`:
///   the staged attachments, kept the same way (``HomeMessagesAttachmentDrafts``);
///   `attachments.prepare.*`: a photo's or video's bytes through the host's preparation before they
///   upload, location removed unless kept (``HomeAttachmentPreparer``).
/// - `outbox.load {}` -> `{pending}`; `outbox.save {conversation, pending}`: the unsent sends, kept the
///   same way (``HomeMessagesOutbox``).
/// - `requests.list {}` -> `{requests}`; `requests.answer {conversation, answer}` -> `{ok}`.
/// - `group.info {conversation}` -> `{info, addable}`; `group.rename|add|remove|mute|chiefReplies` -> `{outcome}`.
/// - `contacts {}` -> `{contacts, inviteTeam, pendingInvites}`.
/// - `chief.create {name, backend}`, `invite.send {email}`, `start {recipients, text}` -> `{outcome}`
///   (``HomeMessagesFirstSend``: a first send with no answer comes with its outbox row).
/// - `teamInvite.seatImpact {}` -> `{impact}`; `teamInvite.send {email}` -> `{result}`.
/// - `linkPreview {url, kind, details}` -> a preview (cards/links/linkPreview.ts); `approval.decide` (``HomeMessagesApprovals``).
/// - `headerPanels.toggle {id}`: runs that panel's action as the person's own (a click only).
/// - Clicks: `chief.settings {conversation, anchor}` -> `{shown}` (the settings under the name pill, page points),
///   `chief.place {conversation, anchor}` (the Teleport menu), `needsYou.action` (the Feed page's `cmux.app.action.run`);
///   ``HomePageAttachmentDrag``'s drag out; Stop, Stop all agents, Continue, Restart and Start now are ``HomeMessagesChiefTurn``'s.
/// Streams: `appearance` (the bubble look, each chat's colours, the composer's spell checking),
/// `group.follow {conversation}` and `requests.follow` (Group Info and Requests while they show,
/// ``HomeMessagesFollow``), `headerPanels` (the toggles of
/// the open conversation), `hidden` (`{hidden: {id: seq}}`: the conversations deleted from the
/// list, each listed again by a message after its seq), `chiefFace` (`{conversation, picture?, text?}`),
/// `chiefPlace` (`{conversation, chip}`: ``ChiefTeleportChipFace``, or null), `needsYou` (``needsYouState()``),
/// `seeThrough` (``HomeMessagesSeeThrough``) and `dictation` (``HomePageDictation``; with its op), each sent on subscribe and on every change.
/// Needs you is the Feed page's own view (webviews/src/pages/feed/NeedsYouView.tsx) drawn in this page: its `cmux.feed.*`
/// calls and streams go on the Feed page's relay (``feedContext(_:)``) and its actions run as the Feed page's, only while the section shows.
@MainActor
final class HomeMessagesHostProvider: PageProvider {
    /// The ops this provider answers, under ``HomeMessagesPageRoute/prefix`` (the router picks the
    /// longest prefix, so these win over the route's own `menu`, `perform` and `chrome`).
    static let prefixes = ["selected", "drafts.", "attachments.", "outbox.", "hidden", "requests.", "group.", "contacts", "composing", "chief.", "invite.", "teamInvite.", "start",
                           "linkPreview", "openLink", "headerPanels", "appearance", "approval.", "chiefFace", "chiefPlace", "needsYou", "dictation", HomePageAttachmentDrag.op, HomePageToastAvoidance.op,
                           HomeMessagesBubbleOps.prefix, HomeMessagesSeeThrough.stream].map { HomeMessagesPageRoute.prefix + $0 }

    private weak var services: AppServices?
    /// What the page shows, as it last said (``HomeMessagesShown``: New Message keeps the conversation open before it).
    private(set) var page = HomeMessagesShown()
    var shown: ConversationID? { page.conversation }
    /// The page's report changed what it shows (its first report too).
    var onShown: (@MainActor (ConversationID?, Bool) -> Void)?
    /// The `hidden` stream: the deleted conversations and the archived Chiefs' ones.
    let hidden = HomeMessagesHiddenFeed()
    /// The `list` stream (tags, Cloud note, teammates, header sizes) and the list's width (``HomeMessagesListFeed``).
    let list: HomeMessagesListFeed
    private lazy var previews = HomeLinkPreviewProvider(services: services)
    private var keeping: HomeMessagesKept?
    private var bubbleOps: HomeMessagesBubbleOps?
    /// Stop, Stop all agents, Continue and Restart on the conversation's own Chief (``HomeMessagesChiefTurn``).
    private lazy var chiefTurn = HomeMessagesChiefTurn { [weak services] id in services.map { services in
        HomeChiefControl(services: services, conversation: id, muxHome: HomeBrainHost.muxHome(tag: services.environment.tag),
                         chief: services.home.homeStore.namedChief(of: id)).turnControl
    } }
    /// The first run of an empty Chief chat (``HomeMessagesFirstRunProvider``): it follows ``shown``.
    var firstRun: HomeMessagesFirstRunProvider?
    /// The `appearance` and `headerPanels` streams (``HomePageStream``: observed only while one has a listener).
    private lazy var appearanceStream = HomePageStream(observing: { [weak self] in self?.appearance() ?? .null })
    private lazy var panelsStream = HomePageStream(observing: { [weak self] in self?.panels() ?? .null })
    private lazy var needsYouStream = HomePageStream(observing: { [weak self] in self?.needsYouState() ?? .null })
    private let chiefFace = HomePageStream(initial: .null)
    private lazy var chiefPlace = HomePageStream(observing: { [weak self] in self?.place() ?? .null })
    /// The page's Chief controls for conversation `id` (its name pill's settings, the location chip's menu);
    /// nil when the page does not show that Chief. Set by the view that holds the page.
    var chiefShown: @MainActor (ConversationID) -> HomeChiefSurface? = { _ in nil }
    /// Settings > Notifications > Feed > Pin Needs You in Chief (opt-in, off by default), and the Feed page's actions provider.
    lazy var needsYouEnabled = HomeNeedsYouSetting.reader { [weak services] in services?.settings }
    private lazy var feedActions = services.map { AppPageNativeProvider(services: $0, page: .feed) }
    /// The window the page is in (the header panels read it).
    var window: () -> NSWindow? = { nil }
    /// The files the app hands the page's composer, by token, while it reads them (``HomeComposerHandoff``).
    let composerFiles = HomeComposerFiles()
    /// The mic, the compose bar's box toasts rest above, and the see-through Chief's switch and header height.
    let dictation = HomePageDictation(), toastAvoidance = HomePageToastAvoidance(), seeThrough = HomeMessagesSeeThrough()
    private lazy var attachmentDrag = HomePageAttachmentDrag(window: { [weak self] in self?.window() }, personOnly: RefusalStrings.personOnlyFromPage) { [weak self] in try? await self?.services?.home.homeStore.fetchAttachment($0, at: $1, variant: .original) }

    init(services: AppServices, widthKey: String) {
        self.services = services
        list = HomeMessagesListFeed(widthKey: { widthKey })
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let services else { throw PageError.unavailable("cmux is closing") }
        if op.hasPrefix(Self.feedPrefix) { return try await DaemonPageRelay(services: services).call(op, params: params, context: try feedContext(context)) }
        let home = services.home
        let fields = params.objectValue ?? [:]
        let name = op.hasPrefix(HomeMessagesPageRoute.prefix) ? String(op.dropFirst(HomeMessagesPageRoute.prefix.count)) : op
        if let answer = try await kept(home).call(name, fields, context: context) { return answer }
        let userOnly = context.userGesture ? nil : PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        if let answer = try await bubbles(services).call(name, fields, refusal: userOnly) { return answer }
        if let userOnly, HomeMessagesPageRoute.needsPerson(name, fields) { throw userOnly }
        let chiefAnswer = try await chiefTurn.call(name, fields, userGesture: context.userGesture)
        if let answer = try chiefAnswer ?? toastAvoidance.call(name, fields) ?? seeThrough.call(name, fields) ?? attachmentDrag.call(name, fields, userGesture: context.userGesture) { return answer }
        switch name {
        case "selected":
            let id = fields["conversation"]?.stringValue.flatMap { Self.isID($0) ? ConversationID($0) : nil }
            reportShown(id, composing: id == nil && fields["composing"]?.boolValue == true)
            return .null
        case "requests.list":
            await home.requests.reload()
            return .object(["requests": .array(home.requests.items.map(\.pageJSON))])
        case "requests.answer":
            let id = try conversation(fields)
            guard let answer = fields["answer"]?.stringValue.flatMap(HomeRequestAnswer.init(pageText:)) else { throw PageError.invalidParams("answer must be accept, decline or block") }
            let ok = await home.requests.answer(id, answer)
            if ok, answer == .accept { home.pendingSelection = id }
            return .object(["ok": .bool(ok)])
        case "group.info":
            let id = try conversation(fields)
            let actions = home.groupActions
            guard let info = actions.info(id) else { throw PageError(code: "cmux.home.unknown_conversation", message: HomeGroupOutcome.unknownConversation.message ?? "") }
            return info.pageAnswer(addable: actions.addable(to: id))
        case "group.rename":
            let id = try conversation(fields)
            return (await home.groupActions.rename(id, to: fields["title"]?.stringValue ?? "")).pageOutcome
        case "group.add":
            let id = try conversation(fields)
            let people = (fields["people"]?.arrayValue ?? []).compactMap(\.stringValue).map { ParticipantID($0) }
            return (await home.groupActions.add(people, to: id, naming: fields["names"]?.stringValue ?? "")).pageOutcome
        case "group.remove":
            let id = try conversation(fields)
            guard let person = fields["participant"]?.stringValue, !person.isEmpty else { throw PageError.invalidParams("participant must be an id") }
            return (await home.groupActions.remove(ParticipantID(person), from: id)).pageOutcome
        case "group.mute":
            let id = try conversation(fields)
            return (home.groupActions.setMuted(fields["muted"]?.boolValue == true, id)).pageOutcome
        case "group.chiefReplies":
            let id = try conversation(fields)
            guard let policy = fields["replies"]?.stringValue.flatMap(ChiefReplyPolicy.init(argument:)) else {
                throw PageError.invalidParams("replies must be auto, mentions or all")
            }
            return (await home.groupActions.setChiefReplies(policy, id)).pageOutcome
        case "contacts":
            let team = services.cloud.isSignedIn ? services.cloud.auth.activeTeam.team?.displayName : nil
            return HomeContact.pageAnswer(home.chiefRoster.mainFirst(home.contacts(), rows: home.homeStore.rows), inviteTeam: team, rows: home.homeStore.rows, roster: home.chiefRoster, harnesses: home.directory.chiefHarnesses)
        case "chief.create":
            let name = (fields["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw PageError.invalidParams("name must not be empty") }
            let backend = fields["backend"]?.stringValue.flatMap(ChiefBackend.init(id:)) ?? .claude
            return (await home.createChief(named: name, backend: backend)).pageOutcome
        case "invite.send":
            let text = fields["email"]?.stringValue ?? ""
            guard let address = ContactAddress.parse(text), address.isEmail else { return HomeComposeOutcome.invalidAddress(text).pageOutcome }
            return (await home.invite(address)).pageOutcome
        case "teamInvite.seatImpact":
            guard let team = services.cloud.auth.activeTeam.team else { return .object(["impact": .object(["kind": .string("unknown")])]) }
            return .object(["impact": await HomeTeamInviteRun.seatImpact(of: team.id, auth: services.cloud.auth).pageJSON])
        case "teamInvite.send":
            guard let team = services.cloud.auth.activeTeam.team else { return .object(["result": .object(["kind": .string("notAllowed")])]) }
            let text = fields["email"]?.stringValue ?? ""
            guard let address = ContactAddress.parse(text), address.isEmail else { return .object(["result": .object(["kind": .string("sendFailed")])]) }
            let answer = await services.cloud.auth.inviteOne(address.description, toTeam: team.id)
            return .object(["result": .object(["kind": .string(answer.rawValue)])])
        case "start":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            return await HomeMessagesFirstSend(store: home.homeStore, contacts: home.contacts(), start: { await home.startConversation($0, title: "", firstMessage: $1, select: false) },
                                               refusal: { home.composer.outcome(for: $0, naming: $1) }, select: { home.pendingSelection = $0 }).run(fields)
        case "chief.settings", "chief.place":
            let chief = chiefShown(try conversation(fields))
            let anchor = HomeChiefSettingsAnchor.box(fields["anchor"])
            if name == "chief.settings" { return .object(["shown": .bool(chief?.toggleSettings(under: anchor) ?? false)]) }
            if let chief, let anchor { chief.openTeleportMenu(under: anchor) }
            return .null
        case "needsYou.action":
            guard let feedActions else { throw PageError.unavailable("cmux is closing") }
            return try await feedActions.call(PageNativeOp.actionRun, params: params, context: try feedContext(context))
        case "dictation": return try dictation.call(params)
        case "linkPreview":
            guard let text = fields["url"]?.stringValue, let url = URL(string: text),
                  let kind = fields["kind"]?.stringValue.flatMap(HomeLinkChipKind.init(rawValue:)) else {
                throw PageError.invalidParams("url and kind must name a link")
            }
            let quick = previews.preview(for: url, kind: kind)
            return (fields["details"]?.boolValue == true ? await previews.details(for: url, preview: quick) : quick).pageJSON(maxLines: HomeLinkPreview.maxLines)
        case "openLink":
            // A chip's app link or path: the Home workspace's right side opens it, as a click in Channels does.
            guard let text = fields["url"]?.stringValue,
                  let url = URL(string: text).flatMap({ $0.scheme == nil ? nil : $0 }) ?? (text.hasPrefix("/") ? URL(fileURLWithPath: text) : nil) else {
                throw PageError.invalidParams("url must name a link or a path")
            }
            home.dock.openLink(url, on: services.daemon.connection)
            return .object(["opened": .bool(true)])
        case "headerPanels.toggle":
            guard let id = fields["id"]?.stringValue else { throw PageError.invalidParams("id must name a panel") }
            return .object(["ran": .bool(HomeHeaderPanels.toggle(id, panelContext(services)))])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        let key = UUID()
        if stream.hasPrefix(Self.feedPrefix), let services {
            return try await DaemonPageRelay(services: services).subscribe(stream, filter: filter, context: try feedContext(context), onEvent: onEvent)
        }
        switch stream {
        case HomeMessagesPageRoute.prefix + "appearance": return appearanceStream.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "group.follow":
            guard let actions = services?.home.groupActions else { throw PageError.unavailable("cmux is closing") }
            let id = try conversation(filter.objectValue ?? [:])
            return HomeMessagesFollow.start({ actions.info(id)?.pageAnswer(addable: actions.addable(to: id)) }, onEvent: onEvent)
        case HomeMessagesPageRoute.prefix + "requests.follow":
            guard let requests = services?.home.requests else { throw PageError.unavailable("cmux is closing") }
            requests.refresh()
            return HomeMessagesFollow.start({ .object(["requests": .array(requests.items.map(\.pageJSON))]) }, onEvent: onEvent)
        case HomeMessagesPageRoute.prefix + "hidden":
            hidden.subscribe(key, onEvent)
            return PageSubscription { [weak self] in self?.hidden.unsubscribe(key) }
        case HomeMessagesPageRoute.prefix + "headerPanels": return panelsStream.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "chiefFace": return chiefFace.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "dictation": return dictation.stream.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + HomeMessagesSeeThrough.stream: return seeThrough.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "chiefPlace":
            _ = services?.chiefTeleport.refresh()
            return chiefPlace.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "needsYou": return needsYouStream.subscribe(onEvent)
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// Follows `chief`'s face for the `chiefFace` stream.
    func follow(_ chief: HomeChiefSurface) {
        let id = chief.conversation
        chief.onFace = { [weak self] picture, text in
            var face: [String: JSONValue] = ["conversation": .string(id.rawValue)]
            if let picture { face["picture"] = .string(picture) }
            if let text { face["text"] = .string(text) }
            self?.chiefFace.publish(.object(face))
        }
    }

    /// The header's location chip on the conversation that shows it (``HomeService/showsTeleport(conversation:)``).
    private func place() -> JSONValue {
        guard let services, let shown, services.home.showsTeleport(conversation: shown.rawValue),
              let face = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(services.chiefTeleport.chipFace(saysAway: true)))
        else { return .null }
        return .object(["conversation": .string(shown.rawValue), "chip": face])
    }

    /// The Needs you section: `{route}` (the Feed page's route the page draws) while the shown conversation is a
    /// Chief's and the section is on, else null. Off, the page mounts no Feed view, so it reads no Feed state.
    func needsYouState() -> JSONValue {
        let store = services?.home.homeStore
        return Self.needsYouState(isChief: shown.flatMap { id in store?.rows.first { $0.id == id } }?.kind == .chief, enabled: needsYouEnabled)
    }

    /// The section's state: `enabled` is read only for a Chief's chat, so another chat never observes the setting.
    static func needsYouState(isChief: Bool, enabled: () -> Bool) -> JSONValue {
        isChief && enabled() ? .object(["route": .string("#/needs-you")]) : .null
    }

    /// The Feed page's ops this page's Needs you sends (``PageFactory/feedWebPage(route:)``'s relay route).
    static let feedPrefix = "cmux.feed."

    /// `context` as the Feed page's (its relay, its actions), with the person's gesture and op id kept; refused while
    /// Needs you does not show, so no other part of this page reads the Feed.
    func feedContext(_ context: PageCallContext) throws -> PageCallContext {
        guard needsYouState() != .null else { throw PageError.unavailable("Needs you is not shown") }
        return Self.asFeedPage(context)
    }

    /// `context` as the Feed page's own call (``PageDescriptor/feed``), the gesture, origin and op id kept.
    static func asFeedPage(_ context: PageCallContext) -> PageCallContext {
        PageCallContext(page: PageDescriptor.feed.id, origin: context.origin, confirmed: context.confirmed, opid: context.opid,
                        userGesture: context.userGesture, gestureEvent: context.gestureEvent)
    }

    /// The page says what it shows (`selected`).
    func reportShown(_ id: ConversationID?, composing: Bool) {
        guard let moved = page.report(id, composing: composing) else { return }
        onShown?(page.conversation, composing)
        if moved { [panelsStream, chiefPlace, needsYouStream].forEach { $0.restart() }; firstRun?.restart() }
    }

    // MARK: Streams

    private func appearance() -> JSONValue {
        guard let home = services?.home else { return .null }
        return HomeChatColorStore.pageAppearance(home.chatColors, spellChecking: services?.settings?.snapshot.agentPaneComposer.spellChecking ?? false)
    }

    /// What the header's toggles read: the page's window and its open conversation's Chief.
    private func panelContext(_ services: AppServices) -> HomeHeaderPanelContext {
        let home = services.home
        let row = shown.flatMap { id in home.homeStore.rows.first { $0.id == id } }
        let control = shown.map { HomeChiefControl(services: services, conversation: $0, muxHome: HomeBrainHost.muxHome(tag: services.environment.tag)) }
        return HomeHeaderPanelContext(services: services, window: window().flatMap { services.windows.owner(of: $0) },
                                      isChief: row?.kind == .chief, chief: control?.named, server: control?.server?.machineID)
    }

    private func panels() -> JSONValue {
        guard let services else { return .null }
        let context = panelContext(services)
        let registry = services.registry
        let states: [JSONValue] = HomeHeaderPanels.all.filter { $0.isShown(context) }.map { panel in
            var fields: [String: JSONValue] = ["id": .string(panel.id), "isOn": .bool(panel.isOpen(context))]
            if let shortcut = registry.shortcutDisplay(for: panel.action) { fields["shortcut"] = .string(shortcut) }
            return .object(fields)
        }
        return .object(["enabled": .bool(HomeTunables.headerPanelToggles.value), "panels": .array(states)])
    }

    /// The bubble menus' app rows (``HomeMessagesBubbleOps``): Retry Reply through the Chief's control, Forward… as Send To…, the file rows.
    private func bubbles(_ services: AppServices) -> HomeMessagesBubbleOps {
        if let bubbleOps { return bubbleOps }
        let files = HomeFileActions(services: services), registry = services.registry, home = HomeBrainHost.muxHome(tag: services.environment.tag)
        let made = HomeMessagesBubbleOps(store: services.home.homeStore, host: .init(linkScheme: services.linkScheme, retryReply: { [weak services] id in
            guard let control = services.map({ HomeChiefControl(services: $0, conversation: id, muxHome: home).turnControl }), !control.isHosted else { return nil }
            return { if case .success = await control.retryChief(message: $0) { true } else { false } }
        }, forward: { registry.perform("home.sendSelectionTo", invocation: ActionInvocation(arguments: ["text": .string($0)], origin: .user)) },
            openFile: { files.open($0) }, fileMenu: { files.menuItems(forFileNamed: $0, resolve: $1) }))
        bubbleOps = made
        return made
    }

    /// The drafts, staged files and unsent sends kept in HomeStore (``HomeMessagesKept``).
    private func kept(_ home: HomeService) -> HomeMessagesKept {
        if let keeping { return keeping }
        let made = HomeMessagesKept(store: home.homeStore, keepLocation: { [weak services] in services?.settings?.snapshot.homeKeepLocation ?? false }, approvals: services.map { ChiefApprovalDecider(home: home.chief.home, app: QuitAgents.environment($0), work: $0.work, environment: ChiefHomeAcpmux.environment) })
        keeping = made
        return made
    }

    // MARK: Wire

    private func conversation(_ fields: [String: JSONValue]) throws -> ConversationID { try HomeMessagesKept.conversation(fields) }

    static func isID(_ text: String) -> Bool { !text.isEmpty && text.count <= 256 }
}
