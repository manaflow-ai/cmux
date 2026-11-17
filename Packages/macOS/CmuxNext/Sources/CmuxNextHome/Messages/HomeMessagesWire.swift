import AppKit
import CmuxNextDesign
public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextHomeModel
public import CmuxNextSettings
public import Foundation
import MessagesLabHome

// The Messages page's wire (`webviews/src/pages/home-messages`): the Home model values its host
// (the App's `HomeMessagesHostProvider`) sends, in the shapes the page parses (sheets/wire.ts,
// detail/detailHost.ts, cards/links/linkPreview.ts). Values only: no view, no service.

extension HomeChatColorStore {
    /// The `appearance` stream (detail/detailHost.ts parseAppearance): the bubble look, a Chief's
    /// look, the default and per-chat colours (Settings > Design), and the composer's spell checking.
    @MainActor public static func pageAppearance(_ store: HomeChatColorStore, spellChecking: Bool) -> JSONValue {
        let design = DesignSettings.shared
        let chats = store.chats.reduce(into: [String: JSONValue]()) { $0[$1.key] = $1.value.pageJSON }
        return .object([
            "look": .string("imessage"),
            "chiefLook": .string(design.homeChiefBubblesThemed ? "theme" : "imessage"),
            "defaults": Self.colors(fromHexes: design.homeBubbleColors).pageJSON,
            "colors": .object(chats),
            "spellChecking": .bool(spellChecking),
        ])
    }
}

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

extension HomeContact {
    /// `contacts`' answer (sheets/wire.ts parseContactsAnswer): the people New Message offers, the
    /// team an invite row names, and the invites still pending (the Invite sheet's list, as the
    /// native HomeInviteSheet's `pending`: each address invited into a conversation not joined yet).
    /// A Chief's entry carries its `look` (``HomeChiefRoster/pageLook(of:rows:harnesses:now:)``).
    @MainActor public static func pageAnswer(_ contacts: [HomeContact], inviteTeam: String?, rows: [InboxRow],
                                  roster: HomeChiefRoster = HomeChiefRoster(), harnesses: [String: String] = [:], now: Date = Date()) -> JSONValue {
        let entries: [JSONValue] = contacts.map { contact in
            guard case .object(var fields) = contact.pageJSON, let look = roster.pageLook(of: contact, rows: rows, harnesses: harnesses, now: now) else {
                return contact.pageJSON
            }
            fields["look"] = look
            return .object(fields)
        }
        return .object(["contacts": .array(entries), "inviteTeam": inviteTeam.map(JSONValue.string) ?? .null,
                        "pendingInvites": .array(rows.pendingInvites.map { .string($0.contact) })])
    }
}

extension HomeChiefRoster {
    /// How New Message's To: list tells a Chief apart (the native HomeChiefRoster+NewMessage `look`):
    /// `tag`, where it runs as the Home list tags it ("Main · Cloud", "This Mac", with a non-default
    /// engine), and `activity`, "Active 2 hours ago" or "No messages yet" (shown only to tell alike
    /// Chiefs apart). Nil for anyone else, or a Chief with no conversation listed.
    @MainActor public func pageLook(of contact: HomeContact, rows: [InboxRow], harnesses: [String: String], now: Date) -> JSONValue? {
        guard contact.source == .agent,
              let row = rows.first(where: { $0.kind == .chief && $0.summary.participants.contains { $0.id == contact.id } }) else { return nil }
        var fields: [String: JSONValue] = ["activity": .string(Self.activity(of: row, now: now))]
        if let tag = tag(for: row.id, engine: ChiefBackend.badge(for: harnesses[contact.id.rawValue])) { fields["tag"] = .string(tag) }
        return .object(fields)
    }

    /// "Active 2 hours ago" for a Chief's conversation, or "No messages yet" for an empty one.
    static func activity(of row: InboxRow, now: Date) -> String {
        guard row.summary.lastSeq > 0 else { return HomeConversationStrings.noMessagesYet }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return HomeConversationStrings.activeAgo(formatter.localizedString(for: min(row.timestamp, now), relativeTo: now))
    }
}

extension HomeGroupInfo {
    /// `group.info`'s answer and each event of `group.follow` (sheets/wire.ts parseGroupInfoAnswer).
    public func pageAnswer(addable: [HomeContact]) -> JSONValue {
        .object(["info": pageJSON, "addable": .array(addable.map(\.pageJSON))])
    }

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

extension HomeGroupOutcome {
    /// The refusal of a `home.messages.present` the page did not present, as the person reads it:
    /// Group Info of a conversation the page does not list is an unknown conversation (the native
    /// TopHomePageView.presentGroupInfo refused it so); nil for any other answer.
    public static func presentRefusal(sheet: String, answer: JSONValue?) -> String? {
        guard sheet == "groupInfo", answer?.objectValue?["presented"]?.boolValue == false else { return nil }
        return unknownConversation.message ?? ""
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
    /// The page's answer to a request (`requests.answer`): accept, decline or block.
    public init?(pageText text: String) {
        switch text {
        case "accept": self = .accept
        case "decline": self = .decline
        case "block": self = .block
        default: return nil
        }
    }
}

extension HomeLinkPreview {
    /// As the Messages page reads it (cards/links/linkPreview.ts); at most `maxLines` lines.
    public func pageJSON(maxLines: Int) -> JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(kind.rawValue), "title": .string(title)]
        if let place { fields["place"] = .string(place) }
        if let status { fields["status"] = .string(status) }
        fields["statusTone"] = .string(statusTone == .success ? "success" : statusTone == .danger ? "danger" : "secondary")
        if !lines.isEmpty { fields["lines"] = .array(lines.prefix(maxLines).map(JSONValue.string)) }
        if monospaced { fields["monospaced"] = .bool(true) }
        if let thumbnail, let png = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) {
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
