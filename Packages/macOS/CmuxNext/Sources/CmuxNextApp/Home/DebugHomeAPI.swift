import CmuxHomeCore
import CmuxNextHostedChief
import CmuxNextSettings
import Foundation

/// `debug.home.api`: drives the one Home data path both front ends use
/// (`HomeService.homeRouter`, docs in Packages/Shared/CmuxHomeCore/README.md)
/// from the debug socket, so a behavior check goes through the real owners.
/// `{call: "inbox"}`, `{call: "snapshot", conversation, tail?}`,
/// `{call: "submit", op: {kind, ...}}`; see `op(_:)` for the kinds;
/// `{call: "chief_switch", choice}` (DebugHome+Hosted.swift); `{call: "rename_chief", conversation, name}`;
/// `{call: "edit_picture", conversation, path, zoom, save}`.
enum DebugHomeAPI {
    static func handle(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        let (router, me) = await MainActor.run { (services.home.homeRouter, services.home.homeSource.me.id) }
        do {
            switch params["call"]?.stringValue {
            case "inbox":
                let inbox = try await router.inbox()
                return .object(["me": .string(inbox.me.id.rawValue),
                                "conversations": .array(inbox.conversations.map { summary($0, me: me) })])
            case "snapshot":
                guard let id = params["conversation"]?.stringValue else { return failure("conversation required") }
                let page = try await router.snapshot(of: ConversationID(id), tail: params["tail"]?.intValue ?? 50)
                return .object(["conversation": summary(page.conversation, me: me), "messages": .array(page.messages.map(message))])
            case "submit":
                guard let op = op(params["op"] ?? .null) else { return failure("unsupported_kind") }
                let result = try await router.submit(HomeIntent(op: op))
                return .object(["ok": .bool(true), "rev": JSONValue(Int(result.rev)), "replayed": .bool(result.replayed),
                                "conversation": result.conversation.map { .string($0.rawValue) } ?? .null])
            case "chief_switch":
                guard let choice = params["choice"]?.stringValue.flatMap(HomeChiefChoice.init(rawValue:)) else { return failure("choice must be hosted or placed") }
                return await MainActor.run { services.home.hostedChief.pick(choice); return DebugHome.hosted(services.home) }
            case "rename_chief":
                // The header card's rename (HomeService.renameChief) of `conversation`, else of the default Chief's.
                guard let name = params["name"]?.stringValue else { return failure("name required") }
                guard let id = await MainActor.run(body: { params["conversation"]?.stringValue ?? services.home.defaultChiefConversation }) else {
                    return failure("no Chief conversation")
                }
                return await renameChief(id, to: name, services: services)
            case "edit_picture":
                // A picture picked or dropped on the Chief card (issue 27915): Move and Scale opens; `save` presses Save.
                guard let path = params["path"]?.stringValue else { return failure("path required") }
                let zoom = params["zoom"]?.doubleValue.map { CGFloat($0) }
                let save = params["save"]?.boolValue ?? false
                return await editPicture(params["conversation"]?.stringValue, path: path, zoom: zoom, save: save, services: services)
            case "chief_names":
                // Every surface's name for `conversation`'s Chief (else the default Chief's), issue 26393.
                return await MainActor.run { chiefNames(params["conversation"]?.stringValue, services: services) }
            case "watch_start":
                return await MainActor.run { DebugHomeWatch.start(router) }
            case "watch_read":
                return await MainActor.run { DebugHomeWatch.read() }
            case "store":
                guard let id = params["conversation"]?.stringValue else { return failure("conversation required") }
                return await MainActor.run { DebugHomeWatch.store(services.home.homeStore, conversation: ConversationID(id)) }
            default:
                return failure("call must be inbox, snapshot, submit, chief_switch, rename_chief, edit_picture, watch_start, watch_read or store")
            }
        } catch {
            return failure(String(describing: error))
        }
    }

    /// `rename_chief`: the header card's rename; `failure` is why it did not save, null when it did,
    /// and `names` every surface's name right after (``chiefNames(_:services:)``).
    @MainActor static func renameChief(_ id: String, to name: String, services: AppServices) async -> JSONValue {
        let failure = await services.home.renameChief(conversation: id, to: name)
        return .object(["ok": .bool(failure == nil), "failure": failure.map { .string(String(describing: $0)) } ?? .null,
                        "names": chiefNames(id, services: services)])
    }

    /// `edit_picture`: Move and Scale over the Home view showing `conversation`'s Chief (else the
    /// default Chief's); `opened` is whether the editor showed, `saved` whether Save wrote the picture.
    @MainActor static func editPicture(_ conversation: String?, path: String, zoom: CGFloat?, save: Bool,
                                       services: AppServices) async -> JSONValue {
        let home = services.home
        guard let id = conversation ?? home.defaultChiefConversation else { return failure("no Chief conversation") }
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let view = home.debugHostViews.allObjects.first(where: { $0.debugConversation == id && $0.window != nil }) else {
            return failure("no Home view shows \(id)")
        }
        let result = await view.debugEditPicture(URL(fileURLWithPath: path), zoom: zoom, save: save)
        return .object(["ok": .bool(result != nil), "opened": .bool(result != nil), "saved": .bool(result == true)])
        #else
        return failure("edit_picture is DEBUG only")
        #endif
    }

    /// `chief_names`: the Chief's name as its tile, header and tab show it, its record's, whether a
    /// rename still shows over the record, the conversation's own title, and `agree` when all
    /// shown names are one.
    @MainActor static func chiefNames(_ conversation: String?, services: AppServices) -> JSONValue {
        let home = services.home
        guard let id = conversation ?? home.defaultChiefConversation else { return failure("no Chief conversation") }
        let key = ConversationID(id)
        let tab = home.homeWorkspace?.screens.flatMap(\.panes).flatMap(\.tabs)
            .first { $0.kind == .conversation && $0.snapshot.conversation?.conversation == id }
        // A header showing this Chief now (a Home tab's, or the Home page's), else none.
        #if DEBUG || CMUX_BENCH_HOOKS
        let header = home.debugHostViews.allObjects.filter { $0.debugConversation == id && $0.window != nil }
            .compactMap(\.transcript.headerTitle).first
        #else
        let header: String? = nil
        #endif
        let tile = home.chiefNames[key]
        let tabTitle = tab.map { home.tabTitle(for: $0) }
        let shown = [tile, header, tabTitle].compactMap { $0 }
        return .object(["conversation": .string(id), "tile": tile.map { .string($0) } ?? .null,
                        "header": header.map { .string($0) } ?? .null, "tab": tabTitle.map { .string($0) } ?? .null,
                        "record": home.chiefRecord(of: key).map { .string($0) } ?? .null,
                        "pending": .bool(home.chiefRenames.isPending(key)),
                        "title": .string(home.conversations.first { $0.id == id }?.title ?? ""),
                        "agree": .bool(!shown.isEmpty && Set(shown).count == 1)])
    }

    /// Kinds: send {conversation, text, thread_root?}, edit {conversation,
    /// message, text}, retract {conversation, message}, react and unreact
    /// {conversation, message, emoji, part?}, read {conversation, seq},
    /// create_group {title, participants}.
    static func op(_ json: JSONValue) -> HomeOp? {
        let conversation = json["conversation"]?.stringValue.map { ConversationID($0) } ?? ConversationID("")
        let message = json["message"]?.stringValue.map { MessageID($0) } ?? MessageID("")
        let text = json["text"]?.stringValue ?? ""
        switch json["kind"]?.stringValue {
        case "send":
            return .sendMessage(conversation: conversation, parts: [.text(text)],
                                threadRoot: json["thread_root"]?.stringValue.map { MessageID($0) })
        case "edit":
            return .editMessage(message: message, conversation: conversation, parts: [.text(text)])
        case "retract":
            return .retractMessage(message: message, conversation: conversation)
        case "react":
            return .addReaction(message: message, conversation: conversation, reaction: .emoji(json["emoji"]?.stringValue ?? ""),
                                partIndex: json["part"]?.intValue ?? 0)
        case "unreact":
            return .removeReaction(message: message, conversation: conversation, reaction: .emoji(json["emoji"]?.stringValue ?? ""),
                                   partIndex: json["part"]?.intValue ?? 0)
        case "read":
            return .setReadCursor(conversation: conversation, seq: Seq(json["seq"]?.intValue ?? 0))
        case "create_group":
            let ids = json["participants"]?.arrayValue?.compactMap(\.stringValue).map { ParticipantID($0) } ?? []
            return .createGroup(title: json["title"]?.stringValue ?? "", participants: ids)
        default:
            return nil
        }
    }

    static func summary(_ summary: ConversationSummary, me: ParticipantID) -> JSONValue {
        .object(["id": .string(summary.id.rawValue), "owner": .string(summary.owner.rawValue), "title": .string(summary.title),
                 "participants": .array(summary.participants.map { .string($0.id.rawValue) }),
                 "last_seq": JSONValue(Int(summary.lastSeq)), "unread": JSONValue(summary.unreadCount(me: me))])
    }

    static func message(_ message: Message) -> JSONValue {
        .object(["id": .string(message.id.rawValue), "seq": JSONValue(Int(message.seq)), "author": .string(message.author.rawValue),
                 "text": .string(message.plainText), "edited": .bool(message.editedAt != nil),
                 "retracted": .bool(message.retractedAt != nil),
                 "reactions": .array(message.reactions.map { reaction in
                     let kind = switch reaction.kind {
                     case .emoji(let emoji): emoji
                     case .tapback(let tapback): tapback.rawValue
                     }
                     return .object(["author": .string(reaction.author.rawValue), "kind": .string(kind)])
                 }),
                 "reply_to": message.replyTo.map { .string($0.message.rawValue) } ?? .null,
                 "thread_root": message.threadRoot.map { .string($0.rawValue) } ?? .null])
    }

    static func failure(_ reason: String) -> JSONValue { .object(["ok": .bool(false), "error": .string(reason)]) }
}
