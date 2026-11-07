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
/// - `contacts {}` -> `{contacts, inviteTeam}`.
/// - `chief.create {name, backend}`, `invite.send {email}`, `start {recipients, text}` -> `{outcome}`.
/// - `teamInvite.seatImpact {}` -> `{impact}`; `teamInvite.send {email}` -> `{result}`.
/// - `linkPreview {url, kind, details}` -> a preview (cards/links/linkPreview.ts).
/// - `headerPanels.toggle {id}`: runs that panel's action as the person's own (a click only).
/// Streams: `appearance` (the bubble look and each chat's colours), `headerPanels` (the toggles of
/// the open conversation) and `hidden` (`{hidden: {id: seq}}`: the conversations deleted from the
/// list, each listed again by a message after its seq), each sent on subscribe and on every change.
@MainActor
final class HomeMessagesHostProvider: PageProvider {
    /// The ops this provider answers, under ``HomeMessagesPageRoute/prefix`` (the router picks the
    /// longest prefix, so these win over the route's own `menu`, `perform` and `chrome`).
    static let prefixes = ["selected", "drafts.", "attachments.", "outbox.", "hidden", "requests.", "group.", "contacts", "chief.", "invite.", "teamInvite.", "start",
                           "linkPreview", "openLink", "headerPanels", "appearance"].map { HomeMessagesPageRoute.prefix + $0 }

    private weak var services: AppServices?
    /// What the page shows, as it last said (``HomeMessagesShown``: New Message keeps the conversation open before it).
    private(set) var page = HomeMessagesShown()
    var shown: ConversationID? { page.conversation }
    /// The page's report changed what it shows (its first report too).
    var onShown: (@MainActor (ConversationID?, Bool) -> Void)?
    /// The `hidden` stream: the deleted conversations and the archived Chiefs' ones.
    let hidden = HomeMessagesHiddenFeed()
    private var previewProvider: HomeLinkPreviewProvider?
    private var keeping: HomeMessagesKept?
    /// The first run of an empty Chief chat (``HomeMessagesFirstRunProvider``): it follows ``shown``.
    var firstRun: HomeMessagesFirstRunProvider?
    private var appearanceListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var panelListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    /// The observation of what the streams read; runs only while one has a listener.
    private var appearanceWatch: Task<Void, Never>?
    private var panelsWatch: Task<Void, Never>?
    /// The window the page is in (the header panels read it).
    var window: () -> NSWindow? = { nil }

    init(services: AppServices) {
        self.services = services
    }

    nonisolated deinit {
        appearanceWatch?.cancel()
        panelsWatch?.cancel()
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let services else { throw PageError.unavailable("cmux is closing") }
        let home = services.home
        let fields = params.objectValue ?? [:]
        let name = op.hasPrefix(HomeMessagesPageRoute.prefix) ? String(op.dropFirst(HomeMessagesPageRoute.prefix.count)) : op
        if let answer = try await kept(home).call(name, fields) { return answer }
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
            return .object(["info": info.pageJSON, "addable": .array(actions.addable(to: id).map(\.pageJSON))])
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
            return .object(["contacts": .array(home.contacts().map(\.pageJSON)), "inviteTeam": team.map(JSONValue.string) ?? .null])
        case "chief.create":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            let name = (fields["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw PageError.invalidParams("name must not be empty") }
            let backend = fields["backend"]?.stringValue.flatMap(ChiefBackend.init(id:)) ?? .claude
            return (await home.createChief(named: name, backend: backend)).pageOutcome
        case "invite.send":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            let text = fields["email"]?.stringValue ?? ""
            guard let address = ContactAddress.parse(text), address.isEmail else { return HomeComposeOutcome.invalidAddress(text).pageOutcome }
            return (await home.invite(address)).pageOutcome
        case "teamInvite.seatImpact":
            guard let team = services.cloud.auth.activeTeam.team else { return .object(["impact": .object(["kind": .string("unknown")])]) }
            return .object(["impact": await HomeTeamInviteRun.seatImpact(of: team.id, auth: services.cloud.auth).pageJSON])
        case "teamInvite.send":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            guard let team = services.cloud.auth.activeTeam.team else { return .object(["result": .object(["kind": .string("notAllowed")])]) }
            let text = fields["email"]?.stringValue ?? ""
            guard let address = ContactAddress.parse(text), address.isEmail else { return .object(["result": .object(["kind": .string("sendFailed")])]) }
            let answer = await services.cloud.auth.inviteOne(address.description, toTeam: team.id)
            return .object(["result": .object(["kind": .string(Self.kind(answer))])])
        case "start":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            return (await start(fields, home: home)).pageOutcome
        case "linkPreview":
            guard let text = fields["url"]?.stringValue, let url = URL(string: text),
                  let kind = fields["kind"]?.stringValue.flatMap(HomeLinkChipKind.init(rawValue:)) else {
                throw PageError.invalidParams("url and kind must name a link")
            }
            let previews = previewProvider ?? HomeLinkPreviewProvider(services: services)
            previewProvider = previews
            let quick = previews.preview(for: url, kind: kind)
            return (fields["details"]?.boolValue == true ? await previews.details(for: url, preview: quick) : quick).pageJSON(maxLines: HomeLinkPreviewProvider.maxLines)
        case "openLink":
            // A chip's app link or path: the Home workspace's right side opens it, as a click in Channels does.
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            guard let text = fields["url"]?.stringValue,
                  let url = URL(string: text).flatMap({ $0.scheme == nil ? nil : $0 }) ?? (text.hasPrefix("/") ? URL(fileURLWithPath: text) : nil) else {
                throw PageError.invalidParams("url must name a link or a path")
            }
            home.dock.openLink(url, on: services.daemon.connection)
            return .object(["opened": .bool(true)])
        case "headerPanels.toggle":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            guard let id = fields["id"]?.stringValue else { throw PageError.invalidParams("id must name a panel") }
            return .object(["ran": .bool(HomeHeaderPanels.toggle(id, panelContext(services)))])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        let key = UUID()
        switch stream {
        case HomeMessagesPageRoute.prefix + "appearance":
            appearanceListeners[key] = onEvent
            onEvent(appearance())
            if appearanceWatch == nil { watchAppearance() }
            return PageSubscription { [weak self] in
                guard let self else { return }
                appearanceListeners[key] = nil
                if appearanceListeners.isEmpty { appearanceWatch?.cancel(); appearanceWatch = nil }
            }
        case HomeMessagesPageRoute.prefix + "hidden":
            hidden.subscribe(key, onEvent)
            return PageSubscription { [weak self] in self?.hidden.unsubscribe(key) }
        case HomeMessagesPageRoute.prefix + "headerPanels":
            panelListeners[key] = onEvent
            onEvent(panels())
            if panelsWatch == nil { restartPanels() }
            return PageSubscription { [weak self] in
                guard let self else { return }
                panelListeners[key] = nil
                if panelListeners.isEmpty { panelsWatch?.cancel(); panelsWatch = nil }
            }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// The page says what it shows (`selected`).
    func reportShown(_ id: ConversationID?, composing: Bool) {
        guard let moved = page.report(id, composing: composing) else { return }
        onShown?(page.conversation, composing)
        if moved { restartPanels(); firstRun?.restart() }
    }

    // MARK: New Message's first send

    /// The blank page's first send (what the native New Message sent first): makes the DM or group with the
    /// recipients and posts `text` there. Addresses only: the email-link start carries the text.
    private func start(_ fields: [String: JSONValue], home: HomeService) async -> HomeComposeOutcome {
        let contacts = home.contacts()
        let recipients: [HomeRecipient] = (fields["recipients"]?.arrayValue ?? []).compactMap { entry in
            if let id = entry["contact"]?.stringValue, !id.isEmpty {
                return .contact(contacts.first { $0.id.rawValue == id } ?? HomeContact(id: ParticipantID(id), name: id, source: .team))
            }
            return entry["address"]?.stringValue.flatMap { ContactAddress.parse($0) }.map(HomeRecipient.address)
        }
        guard !recipients.isEmpty else { return .refused("") }
        let text = (fields["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [MessagePart] = text.isEmpty ? [] : [.text(text)]
        let addressesOnly = recipients.allSatisfy { if case .address = $0 { true } else { false } }
        let outcome = await home.startConversation(recipients, title: "", firstMessage: addressesOnly ? parts : [])
        if case .opened(let id) = outcome, !addressesOnly, !parts.isEmpty {
            // The real store owns the send from here (its offline queue and Not Delivered state).
            _ = try? await home.homeStore.perform(.sendMessage(conversation: id, parts: parts))
        }
        return outcome
    }

    // MARK: Streams

    private func appearance() -> JSONValue {
        guard let home = services?.home else { return .null }
        let design = DesignSettings.shared
        let colors = home.chatColors.chats.reduce(into: [String: JSONValue]()) { $0[$1.key] = $1.value.pageJSON }
        return .object([
            "look": .string("imessage"),
            "chiefLook": .string(design.homeChiefBubblesThemed ? "theme" : "imessage"),
            "defaults": HomeChatColorStore.colors(fromHexes: design.homeBubbleColors).pageJSON,
            "colors": .object(colors),
        ])
    }

    private func watchAppearance() {
        guard let chats = services?.home.chatColors else { return }
        // task-owner: lives while the page listens to `appearance` (cancelled with its last listener); event-driven (Observation)
        appearanceWatch = Task { [weak self] in
            for await _ in ObservationStream({ (chats.chats, DesignSettings.shared.homeBubbleColors, DesignSettings.shared.homeChiefBubblesThemed) }) {
                guard let self else { return }
                let value = appearance()
                for listener in appearanceListeners.values { listener(value) }
            }
        }
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

    /// Follows the toggles while the page listens, for the conversation it shows now.
    private func restartPanels() {
        panelsWatch?.cancel()
        panelsWatch = nil
        guard !panelListeners.isEmpty else { return }
        // task-owner: lives while the page listens to `headerPanels` (restarted on a new conversation, cancelled with its last listener); event-driven (Observation)
        panelsWatch = Task { [weak self] in
            guard let self else { return }
            for await value in ObservationStream({ [weak self] in self?.panels() ?? .null }) {
                for listener in panelListeners.values { listener(value) }
            }
        }
    }

    /// The drafts, staged files and unsent sends kept in HomeStore (``HomeMessagesKept``).
    private func kept(_ home: HomeService) -> HomeMessagesKept {
        if let keeping { return keeping }
        let made = HomeMessagesKept(store: home.homeStore, keepLocation: { [weak services] in services?.settings?.snapshot.homeKeepLocation ?? false })
        keeping = made
        return made
    }

    // MARK: Wire

    private func conversation(_ fields: [String: JSONValue]) throws -> ConversationID {
        guard let id = fields["conversation"]?.stringValue, Self.isID(id) else { throw PageError.invalidParams("conversation must be a conversation id") }
        return ConversationID(id)
    }

    static func isID(_ text: String) -> Bool { !text.isEmpty && text.count <= 256 }

    static func kind(_ answer: CloudTeamInviteAnswer) -> String {
        switch answer {
        case .sent: "sent"
        case .alreadyMember: "alreadyMember"
        case .sendFailed: "sendFailed"
        case .notAllowed: "notAllowed"
        case .unreachable: "unreachable"
        }
    }
}
