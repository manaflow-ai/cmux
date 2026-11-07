import AppKit
public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextHomeModel
public import CmuxNextSettings

// The Messages page's wire (`webviews/src/pages/home-messages`): the Home model values its host
// (the App's `HomeMessagesHostProvider`) sends, in the shapes the page parses (sheets/wire.ts,
// detail/detailHost.ts). Values only: no view, no service.

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
