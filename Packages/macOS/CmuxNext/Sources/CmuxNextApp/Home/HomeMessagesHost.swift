import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeed
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
/// - `selected {conversation | null}`: the page's open conversation (sync actions read it).
/// - `requests.list {}` -> `{requests}`; `requests.answer {conversation, answer}` -> `{ok}`.
/// - `group.info {conversation}` -> `{info, addable}`; `group.rename|add|remove|mute|chiefReplies` -> `{outcome}`.
/// - `contacts {}` -> `{contacts, inviteTeam}`.
/// - `chief.create {name, backend}`, `invite.send {email}`, `start {recipients, text}` -> `{outcome}`.
/// - `teamInvite.seatImpact {}` -> `{impact}`; `teamInvite.send {email}` -> `{result}`.
/// - `linkPreview {url, kind, details}` -> a preview (cards/links/linkPreview.ts).
/// - `headerPanels.toggle {id}`: runs that panel's action as the person's own (a click only).
/// - Clicks: `chief.settings {conversation, anchor}` -> `{shown}` (the settings under the name pill, page points),
///   `chief.stop {conversation, all}`, `chief.continue {conversation}`, `chief.retry {conversation, message}`,
///   `chief.place {conversation, anchor}` (the Teleport menu), `needsYou.open|answer|showAll {id, answer}`.
/// Streams, sent on subscribe and on every change: `appearance` (bubble look, chat colours), `headerPanels`,
/// `chiefTurn` (`{conversation, continueAvailable}`), `chiefFace` (`{conversation, picture?, text?}`),
/// `chiefPlace` (`{conversation, chip}`: ``ChiefTeleportChipFace``, or null), `needsYou` (``FeedNeedsYouRows`` or null).
@MainActor
final class HomeMessagesHostProvider: PageProvider {
    /// The ops this provider answers, under ``HomeMessagesPageRoute/prefix`` (the router picks the
    /// longest prefix, so these win over the route's own `menu`, `perform` and `chrome`).
    static let prefixes = ["selected", "requests.", "group.", "contacts", "chief.", "invite.", "teamInvite.", "start",
                           "linkPreview", "openLink", "headerPanels", "appearance", "chiefTurn", "chiefFace", "chiefPlace", "needsYou"].map { HomeMessagesPageRoute.prefix + $0 }

    private weak var services: AppServices?
    /// The page's open conversation, as it last said.
    private(set) var shown: ConversationID?
    var onShown: (@MainActor (ConversationID?) -> Void)?
    private var previewProvider: HomeLinkPreviewProvider?
    /// The page's streams; an observed one reads only while it has a listener.
    private lazy var appearanceStream = HomePageStream(observing: { [weak self] in self?.appearance() ?? .null })
    private lazy var panelsStream = HomePageStream(observing: { [weak self] in self?.panels() ?? .null })
    private lazy var needsYouStream = HomePageStream(observing: { [weak self] in self?.needsYouRows() ?? .null })
    private let chiefTurn = HomePageStream(initial: .object(["continueAvailable": .bool(false)]))
    private let chiefFace = HomePageStream(initial: .null)
    private lazy var chiefPlace = HomePageStream(observing: { [weak self] in self?.place() ?? .null })
    /// The page's Chief controls for conversation `id` (its name pill's settings, Stop, Continue, Retry,
    /// the location chip's menu); nil when the page does not show that Chief. Set by the view that holds the page.
    var chiefShown: @MainActor (ConversationID) -> HomeChiefSurface? = { _ in nil }
    /// The pinned Needs you section, made on the first listener.
    private var needsYou: FeedNeedsYouPin?
    /// The first run's facts follow the conversation shown (held strongly: the page's route holds it too).
    var firstRun: HomeMessagesFirstRunProvider?
    /// The window the page is in (the header panels read it).
    var window: () -> NSWindow? = { nil }
    /// The files the app hands the page's composer, by token, while it reads them (``HomeComposerHandoff``).
    let composerFiles = HomeComposerFiles()

    init(services: AppServices) {
        self.services = services
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let services else { throw PageError.unavailable("cmux is closing") }
        let home = services.home
        let fields = params.objectValue ?? [:]
        let name = op.hasPrefix(HomeMessagesPageRoute.prefix) ? String(op.dropFirst(HomeMessagesPageRoute.prefix.count)) : op
        switch name {
        case "selected":
            let id = fields["conversation"]?.stringValue.flatMap { Self.isID($0) ? ConversationID($0) : nil }
            if id != shown {
                shown = id
                onShown?(id)
                panelsStream.restart()
                chiefPlace.restart()
                needsYouStream.restart()
                firstRun?.restart()
            }
            return .null
        case "requests.list":
            await home.requests.reload()
            return .object(["requests": .array(home.requests.items.map(\.pageJSON))])
        case "requests.answer":
            let id = try conversation(fields)
            guard let answer = fields["answer"]?.stringValue.flatMap(HomeRequestAnswer.init(pageValue:)) else { throw PageError.invalidParams("answer must be accept, decline or block") }
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
        case "chief.settings", "chief.place", "chief.stop", "chief.continue", "chief.retry":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            let chief = chiefShown(try conversation(fields))
            let box = fields["anchor"]?.objectValue
            let number = { (key: String) in box?[key]?.doubleValue }
            let anchor = number("x").flatMap { x in number("y").flatMap { y in number("width").flatMap { w in number("height").map { h in
                CGRect(x: x, y: y, width: max(1, min(w, 4096)), height: max(1, min(h, 4096)))
            } } } }
            switch name {
            case "chief.settings": return .object(["shown": .bool(chief?.toggleSettings(under: anchor) ?? false)])
            case "chief.place": if let chief, let anchor { chief.openTeleportMenu(under: anchor) }
            case "chief.stop" where fields["all"]?.boolValue == true: chief?.stopAllAgents()
            case "chief.stop": if chief != nil { _ = services.registry.perform(HomeChiefControl.stopAction, invocation: ActionInvocation(origin: .user)) }
            case "chief.continue": chief?.turnActions.continueTurn()
            default:
                guard let message = fields["message"]?.stringValue, Self.isID(message) else { throw PageError.invalidParams("message must be a message id") }
                chief?.turnActions.retry(MessageID(message))
            }
            return .null
        case "needsYou.open", "needsYou.answer", "needsYou.showAll":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage) }
            let item = fields["id"]?.stringValue ?? ""
            switch name {
            case "needsYou.open": needsYou?.open(id: item)
            case "needsYou.answer": needsYou?.answer(item, with: fields["answer"]?.stringValue ?? "")
            default: needsYou?.showFeed()
            }
            return .null
        case "linkPreview":
            guard let text = fields["url"]?.stringValue, let url = URL(string: text),
                  let kind = fields["kind"]?.stringValue.flatMap(HomeLinkChipKind.init(rawValue:)) else {
                throw PageError.invalidParams("url and kind must name a link")
            }
            let previews = previewProvider ?? HomeLinkPreviewProvider(services: services)
            previewProvider = previews
            let quick = previews.preview(for: url, kind: kind)
            return (fields["details"]?.boolValue == true ? await previews.details(for: url, preview: quick) : quick).pageJSON(maxLines: HomeLinkPreview.maxLines)
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
        switch stream {
        case HomeMessagesPageRoute.prefix + "appearance": return appearanceStream.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "headerPanels": return panelsStream.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "chiefTurn": return chiefTurn.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "chiefFace": return chiefFace.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "chiefPlace":
            _ = services?.chiefTeleport.refresh()
            return chiefPlace.subscribe(onEvent)
        case HomeMessagesPageRoute.prefix + "needsYou":
            if let services, needsYou == nil {
                needsYou = FeedNeedsYouPin.home(services)
                services.feed.startIfSignedIn() // the Feed's mirror runs once the account is signed in, as the Feed panel starts it
            }
            return needsYouStream.subscribe(onEvent)
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// Follows `chief`'s turn (Continue after a Stop) for the `chiefTurn` stream.
    func follow(_ chief: HomeChiefSurface) {
        let id = chief.conversation
        chief.turnActions.onContinueAvailable = { [weak self] in self?.publishChiefTurn(id, continueAvailable: $0) }
        publishChiefTurn(id, continueAvailable: chief.turnActions.continueAvailable)
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

    /// The shown Chief's turn changed (``HomeChiefTurnActions/onContinueAvailable``).
    func publishChiefTurn(_ id: ConversationID, continueAvailable: Bool) {
        chiefTurn.publish(.object(["conversation": .string(id.rawValue), "continueAvailable": .bool(continueAvailable)]))
    }

    /// The Needs you section: its rows while the shown conversation is a Chief's and the section is
    /// on (opt-in, off by default), else null. Off reads no Feed state, so the Feed's changes never wake it.
    private func needsYouRows() -> JSONValue {
        guard let pin = needsYou, let store = services?.home.homeStore else { return .null }
        let chief = shown.flatMap { id in store.rows.first { $0.id == id } }?.kind == .chief
        return chief && pin.isEnabled() ? pin.rows().flatMap { try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null : .null
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

/// A Chief chat's pinned Needs you section (``FeedNeedsYouPin``) over the app's Feed, as the page draws it.
@MainActor
extension FeedNeedsYouPin {
    /// The Messages page's pin over the app's Feed, its hooks installed once (the Inbox page installs
    /// the same when it is made: a request's answers, its row's who and where).
    static func home(_ services: AppServices) -> FeedNeedsYouPin {
        let model = services.feed.model, store = services.daemon.store
        if model.onOpenItem == nil { FeedGitHubActions.install(on: model, services: services) }
        if model.place == nil { model.place = FeedPlace.lookup(store.place) }
        let isEnabled = HomeNeedsYouSetting.reader { [weak services] in services?.settings } // opt-in, off by default
        return FeedNeedsYouPin(model: model, isEnabled: isEnabled, prepare: {}, reveal: { [weak services] at in
            store.tab(reported: at.tab, terminal: at.terminal, agentSession: at.acpSession).map { services?.revealTab($0.id) == true } ?? false
        }, showFeed: { [weak services] in try? (services?.pages.provider(.inbox) as? FeedPageService)?.open(focus: true) })
    }
}
