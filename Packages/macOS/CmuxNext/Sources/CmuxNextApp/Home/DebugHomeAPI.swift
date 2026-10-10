import CmuxHomeCore
import CmuxNextSettings
import Foundation

/// `debug.home.api`: drives the one Home data path both front ends use
/// (`HomeService.homeRouter`, docs in Packages/Shared/CmuxHomeCore/README.md)
/// from the debug socket, so a behavior check goes through the real owners.
/// `{call: "inbox"}`, `{call: "snapshot", conversation, tail?}`,
/// `{call: "submit", op: {kind, ...}}`; see `op(_:)` for the kinds.
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
            default:
                return failure("call must be inbox, snapshot or submit")
            }
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Kinds: send {conversation, text}, react {conversation, message,
    /// emoji, part?}, read {conversation, seq}, create_group {title,
    /// participants}.
    static func op(_ json: JSONValue) -> HomeOp? {
        let conversation = json["conversation"]?.stringValue.map { ConversationID($0) } ?? ConversationID("")
        let message = json["message"]?.stringValue.map { MessageID($0) } ?? MessageID("")
        let text = json["text"]?.stringValue ?? ""
        switch json["kind"]?.stringValue {
        case "send":
            return .sendMessage(conversation: conversation, parts: [.text(text)])
        case "react":
            return .addReaction(message: message, conversation: conversation, reaction: .emoji(json["emoji"]?.stringValue ?? ""),
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
