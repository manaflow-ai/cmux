public import CmuxHomeRender
public import CmuxNextHomeModel
public import CmuxNextSettings
import AppKit
import CmuxHomeCore
import CmuxNextDesign
import MessagesLabHome

// The Messages page's wire shapes of the Home models (sheets/wire.ts, sheets/model.ts,
// cards/links/linkPreview.ts and detail/detailHost.ts read them); the app's
// HomeMessagesHostProvider answers with them.

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

extension HomeMessageRequest {
    public var pageJSON: JSONValue {
        let request = self
        var fields: [String: JSONValue] = ["conversation": .string(request.conversation.rawValue), "inviter": .string(request.inviter),
                                           "isGroup": .bool(request.isGroup), "preview": .string(request.preview), "trusted": .bool(request.trusted)]
        if let title = request.title { fields["title"] = .string(title) }
        return .object(fields)
    }
}

extension HomeContact {
    public var pageJSON: JSONValue {
        let contact = self
        let source = switch contact.source {
        case .team: "team"
        case .connection: "connection"
        case .agent: "agent"
        }
        return .object(["id": .string(contact.id.rawValue), "name": .string(contact.name), "source": .string(source)])
    }
}

extension HomeGroupInfo {
    public var pageJSON: JSONValue {
        let info = self
        var fields: [String: JSONValue] = [
            "conversation": .string(info.conversation.rawValue), "isGroup": .bool(info.isGroup), "title": .string(info.title),
            "displayTitle": .string(info.displayTitle), "canMute": .bool(info.canMute), "muted": .bool(info.muted),
            "canAddPeople": .bool(info.canAddPeople), "canRename": .bool(info.canRename),
            "members": .array(info.members.map { member in
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
        if let count = info.memberCount { fields["memberCount"] = .number(Double(count)) }
        if let replies = info.chiefReplies { fields["chiefReplies"] = .string(replies.rawValue) }
        return .object(fields)
    }
}

extension HomeTeamSeatImpact {
    public var pageJSON: JSONValue {
        switch self {
        case .paidSeat(let members): return .object(["kind": .string("paidSeat"), "members": .number(Double(members))])
        case .capped(let members, let limit): return .object(["kind": .string("capped"), "members": .number(Double(members)), "limit": .number(Double(limit))])
        case .free(let members): return .object(["kind": .string("free"), "members": .number(Double(members))])
        case .unknown: return .object(["kind": .string("unknown")])
        case .notAllowed: return .object(["kind": .string("notAllowed")])
        }
    }
}

extension HomeComposeOutcome {
    /// `{outcome: {kind, …}}`, as sheets/model.ts reads it.
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
    /// `{outcome: {kind, …}}`, as sheets/model.ts reads it.
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
    public var pageJSON: JSONValue {
        let colors = self
        var fields: [String: JSONValue] = [:]
        for (role, color) in [("sent", colors.sent), ("sentText", colors.sentText), ("received", colors.received), ("receivedText", colors.receivedText)] {
            if let color { fields[role] = .string(String(color.hex.prefix(7))) }
        }
        return .object(fields)
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
