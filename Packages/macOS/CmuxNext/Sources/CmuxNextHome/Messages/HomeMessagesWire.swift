public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextDesign
public import CmuxNextHomeModel
public import CmuxNextSettings
import AppKit
import MessagesLabHome

// The Messages page's wire (`webviews/src/pages/home-messages`): the Home model values its host
// (the App's `HomeMessagesHostProvider`) sends, in the shapes the page parses (sheets/wire.ts,
// detail/detailHost.ts, cards/links/linkPreview.ts). Values only: no view, no service.

extension HomeMessageRequest {
    /// As the Messages page reads it (sheets/model.ts).
    public var pageJSON: JSONValue {
        var fields: [String: JSONValue] = ["conversation": .string(conversation.rawValue), "inviter": .string(inviter),
                                           "isGroup": .bool(isGroup), "preview": .string(preview), "trusted": .bool(trusted)]
        if let title { fields["title"] = .string(title) }
        return .object(fields)
    }
}

extension HomeContact {
    /// As the Messages page reads it (sheets/model.ts).
    public var pageJSON: JSONValue {
        let source = switch self.source {
        case .team: "team"
        case .connection: "connection"
        case .agent: "agent"
        }
        return .object(["id": .string(id.rawValue), "name": .string(name), "source": .string(source)])
    }
}

extension HomeGroupInfo {
    /// As the Messages page reads it (sheets/model.ts).
    public var pageJSON: JSONValue {
        var fields: [String: JSONValue] = [
            "conversation": .string(conversation.rawValue), "isGroup": .bool(isGroup), "title": .string(title),
            "displayTitle": .string(displayTitle), "canMute": .bool(canMute), "muted": .bool(muted),
            "canAddPeople": .bool(canAddPeople), "canRename": .bool(canRename),
            "members": .array(members.map { member in
                var fields: [String: JSONValue] = ["id": .string(member.id.rawValue), "name": .string(member.name), "isMe": .bool(member.isMe),
                                                   "isAgent": .bool(member.isAgent), "isInvited": .bool(member.isInvited)]
                switch member.role {
                case .owner: fields["role"] = .string("owner")
                case .admin: fields["role"] = .string("admin")
                case .readOnly: fields["role"] = .string("readOnly")
                case .member: fields["role"] = .string("member")
                case nil: break
                }
                return .object(fields)
            }),
        ]
        if let count = memberCount { fields["memberCount"] = .number(Double(count)) }
        if let replies = chiefReplies { fields["chiefReplies"] = .string(replies.rawValue) }
        return .object(fields)
    }
}

extension HomeTeamSeatImpact {
    /// As the Messages page reads it (sheets/model.ts).
    public var pageJSON: JSONValue {
        switch self {
        case .paidSeat(let members): .object(["kind": .string("paidSeat"), "members": .number(Double(members))])
        case .capped(let members, let limit): .object(["kind": .string("capped"), "members": .number(Double(members)), "limit": .number(Double(limit))])
        case .free(let members): .object(["kind": .string("free"), "members": .number(Double(members))])
        case .unknown: .object(["kind": .string("unknown")])
        case .notAllowed: .object(["kind": .string("notAllowed")])
        }
    }
}

extension HomeComposeOutcome {
    /// `{outcome: {kind, …}}`, as the Messages page's sheets read it (sheets/model.ts).
    public var pageOutcome: JSONValue {
        let value: JSONValue = switch self {
        case .opened(let id): .object(["kind": .string("opened"), "conversation": .string(id.rawValue)])
        case .invited(let id): .object(["kind": .string("invited"), "conversation": id.map { .string($0.rawValue) } ?? .null])
        case .notReachable(let name): .object(["kind": .string("notReachable"), "name": .string(name)])
        case .rateLimited: .object(["kind": .string("rateLimited")])
        case .invalidAddress(let text): .object(["kind": .string("invalidAddress"), "text": .string(text)])
        case .offline: .object(["kind": .string("offline")])
        case .cloudUnreachable: .object(["kind": .string("cloudUnreachable")])
        case .refused(let reason): .object(["kind": .string("refused"), "reason": .string(reason)])
        }
        return .object(["outcome": value])
    }

    /// The blank page's first send (what the native New Message sent first): `start` makes the DM or
    /// group with the recipients, and `text` is posted there through `send` (the real store, with its
    /// offline queue and Not Delivered state). Addresses only: the email-link start carries the text.
    public static func pageStart(_ fields: [String: JSONValue], contacts: [HomeContact],
                                 start: (_ recipients: [HomeRecipient], _ firstMessage: [MessagePart]) async -> HomeComposeOutcome,
                                 send: (ConversationID, [MessagePart]) async -> Void) async -> HomeComposeOutcome {
        let recipients = HomeRecipient.page(fields["recipients"], contacts: contacts)
        guard !recipients.isEmpty else { return .refused("") }
        let text = (fields["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [MessagePart] = text.isEmpty ? [] : [.text(text)]
        let addressesOnly = recipients.allSatisfy { if case .address = $0 { true } else { false } }
        let outcome = await start(recipients, addressesOnly ? parts : [])
        if case .opened(let id) = outcome, !addressesOnly, !parts.isEmpty { await send(id, parts) }
        return outcome
    }
}

extension HomeGroupOutcome {
    /// `{outcome: {kind, …}}`, as the Messages page's sheets read it (sheets/model.ts).
    public var pageOutcome: JSONValue {
        let value: JSONValue = switch self {
        case .done: .object(["kind": .string("done")])
        case .queued: .object(["kind": .string("queued")])
        case .left: .object(["kind": .string("left")])
        case .notReachable(let name): .object(["kind": .string("notReachable"), "name": .string(name)])
        case .ownerOnly: .object(["kind": .string("ownerOnly")])
        case .forbidden: .object(["kind": .string("forbidden")])
        case .readOnly: .object(["kind": .string("readOnly")])
        case .notAGroup: .object(["kind": .string("notAGroup")])
        case .unknownConversation: .object(["kind": .string("unknownConversation")])
        case .unknownPerson(let name): .object(["kind": .string("unknownPerson"), "name": .string(name)])
        case .notAMember(let name): .object(["kind": .string("notAMember"), "name": .string(name)])
        case .cannotMute: .object(["kind": .string("cannotMute")])
        case .emptyText: .object(["kind": .string("emptyText")])
        case .noPeople: .object(["kind": .string("noPeople")])
        case .offline: .object(["kind": .string("offline")])
        case .rateLimited: .object(["kind": .string("rateLimited")])
        case .tooMany: .object(["kind": .string("tooMany")])
        case .refused(let reason): .object(["kind": .string("refused"), "reason": .string(reason)])
        }
        return .object(["outcome": value])
    }
}

extension HomeBubbleColors {
    /// As the Messages page reads it (detail/detailHost.ts).
    public var pageJSON: JSONValue {
        var fields: [String: JSONValue] = [:]
        for (role, color) in [("sent", sent), ("sentText", sentText), ("received", received), ("receivedText", receivedText)] {
            if let color { fields[role] = .string(String(color.hex.prefix(7))) }
        }
        return .object(fields)
    }
}

extension HomeRequestAnswer {
    /// The page's word for an answer (`requests.answer`): accept, decline or block.
    public init?(pageValue text: String) {
        switch text {
        case "accept": self = .accept
        case "decline": self = .decline
        case "block": self = .block
        default: return nil
        }
    }
}

extension HomeLinkPreview {
    /// A preview as cards/links/linkPreview.ts reads it, with at most `maxLines` lines.
    public func pageJSON(maxLines: Int) -> JSONValue {
        let preview = self
        var fields: [String: JSONValue] = ["kind": .string(preview.kind.rawValue), "title": .string(preview.title)]
        if let place = preview.place { fields["place"] = .string(place) }
        if let status = preview.status { fields["status"] = .string(status) }
        switch preview.statusTone {
        case .success: fields["statusTone"] = .string("success")
        case .danger: fields["statusTone"] = .string("danger")
        default: fields["statusTone"] = .string("secondary")
        }
        if !preview.lines.isEmpty { fields["lines"] = .array(preview.lines.prefix(maxLines).map(JSONValue.string)) }
        if preview.monospaced { fields["monospaced"] = .bool(true) }
        if let image = preview.thumbnail, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            fields["thumbnail"] = .string("data:image/png;base64," + png.base64EncodedString())
        }
        return .object(fields)
    }
}

extension HomeStore {
    /// The longest draft kept (a paste of a log stays a draft; a runaway page cannot fill the cache).
    public static let maxPageDraftLength = 200_000

    /// `{drafts: {conversation: text}}`: every kept composer draft (`drafts.load`).
    public var pageDrafts: JSONValue {
        let drafts = rows.reduce(into: [String: JSONValue]()) { out, row in
            if let text = draft(for: row.id), !text.isEmpty { out[row.id.rawValue] = .string(text) }
        }
        return .object(["drafts": .object(drafts)])
    }

    /// Keeps `text` as `id`'s draft (`drafts.save`); false when it is longer than a draft keeps.
    public func savePageDraft(_ text: String, for id: ConversationID) -> Bool {
        guard text.count <= Self.maxPageDraftLength else { return false }
        setDraft(text, for: id)
        return true
    }
}

extension [ConversationID: Seq] {
    /// `{hidden: {id: seq}}`: the conversations deleted from the list, each listed again by a message after its seq.
    public var pageHidden: JSONValue {
        .object(["hidden": .object(reduce(into: [String: JSONValue]()) { $0[$1.key.rawValue] = .number(Double($1.value)) })])
    }
}

extension HomeChatColorStore {
    /// The `appearance` stream: the bubble look, the default colours and each chat's own.
    public func pageAppearance(_ design: DesignSettings) -> JSONValue {
        .object([
            "look": .string("imessage"),
            "chiefLook": .string(design.homeChiefBubblesThemed ? "theme" : "imessage"),
            "defaults": Self.colors(fromHexes: design.homeBubbleColors).pageJSON,
            "colors": .object(chats.reduce(into: [String: JSONValue]()) { $0[$1.key] = $1.value.pageJSON }),
        ])
    }
}

extension HomeRecipient {
    /// New Message's recipients as the page sends them (`start {recipients: [{contact} | {address}]}`).
    public static func page(_ entries: JSONValue?, contacts: [HomeContact]) -> [HomeRecipient] {
        (entries?.arrayValue ?? []).compactMap { entry in
            if let id = entry["contact"]?.stringValue, !id.isEmpty {
                return .contact(contacts.first { $0.id.rawValue == id } ?? HomeContact(id: ParticipantID(id), name: id, source: .team))
            }
            return entry["address"]?.stringValue.flatMap { ContactAddress.parse($0) }.map(HomeRecipient.address)
        }
    }
}
