import CmuxHomeCore
import CmuxNextDaemon
import CryptoKit
import Foundation

/// The signed-in account as a Home participant on the cloud owners, and the
/// one id it shows as in the shared Home core.
///
/// One `HomeStore` holds local and cloud conversations and has one `me`
/// (home-mac.md 1: the view takes `HomeStore.me` at creation). The local
/// owner's user is `user_local`; the cloud owners know the same person by the
/// Worker's user id (`participantID`). The cloud mapping writes that id as `localID` on
/// the way in and back on the way out, so every conversation in the store
/// names its user with one id. No other id is rewritten.
public nonisolated struct CloudIdentity: Hashable, Sendable {
    /// `user_<stack id>`: the account as the daemon's lease and sockets name it.
    let cloudID: String
    /// The id the Home store uses for its user.
    let localID: ParticipantID
    let displayName: String

    /// The Worker's participant id for a Stack user id (`user_` prefix once).
    /// The Worker's user id of this account in conversations (backend
    /// domains/user.ts `userIdFor`): `user_` + the first 20 hex digits of
    /// sha256("stack:<project>:<stack user id>"). Without a project (tests)
    /// it is `cloudID`.
    let participantID: String

    init(stackUserID: String, displayName: String, localID: ParticipantID, stackProjectID: String? = nil) {
        cloudID = Self.cloudID(stackUserID: stackUserID)
        participantID = stackProjectID.map { Self.workerUserID(stackProjectID: $0, stackUserID: stackUserID) } ?? cloudID
        self.localID = localID
        self.displayName = displayName
    }

    /// The Worker's participant id for a Stack user id.
    public static func cloudID(stackUserID: String) -> String {
        stackUserID.hasPrefix("user_") ? stackUserID : "user_" + stackUserID
    }

    /// The Worker's user id for a Stack user of a Stack project.
    public static func workerUserID(stackProjectID: String, stackUserID: String) -> String {
        let digest = SHA256.hash(data: Data("stack:\(stackProjectID):\(stackUserID)".utf8))
        return "user_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    /// The Worker's team id for a Stack team of a Stack project (the API's `stackTeamIdFor`), the
    /// id `x-cmux-team` and `user.teams.list` use for the team `ActiveTeam` names by its Stack id.
    public static func workerTeamID(stackProjectID: String, stackTeamID: String) -> String {
        let digest = SHA256.hash(data: Data("stack-team:\(stackProjectID):\(stackTeamID.lowercased())".utf8))
        return "team_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    func toHome(_ id: String) -> ParticipantID { id == participantID || id == cloudID ? localID : ParticipantID(id) }
    func toCloud(_ id: ParticipantID) -> String { id == localID ? participantID : id.rawValue }
    /// This account as a cloud participant (the creator of a new conversation).
    var participant: ConversationParticipant { ConversationParticipant(id: participantID, kind: .human, displayName: displayName) }
}

/// The cloud owners' wire types (through the daemon) as Home core types.
/// Pure. Ids, seqs and revisions pass through unchanged, except the account's
/// own id (`CloudIdentity`).
nonisolated enum CloudHomeMapping {
    static func participant(_ participant: ConversationParticipant, identity: CloudIdentity) -> Participant {
        struct Request: Encodable {
            let participant: ConversationParticipant
            let identity: HomeCoreMapping.Identity
        }
        struct Reply: Decodable { let participant: Participant }
        return HomeCoreMapping.mappingRule("cloudParticipant", Request(participant: participant, identity: .init(identity)), fallback: Reply?.none)?
            .participant ?? Participant(id: identity.toHome(participant.id), kind: .human, displayName: participant.displayName)
    }

    static func message(_ wire: ConversationMessage, identity: CloudIdentity) -> Message {
        HomeCoreMapping.message(wire, identity: identity)
    }

    /// A cloud head (`mapping.cloudSummary`). Participants who left are not members any more.
    static func summary(_ summary: CmuxNextDaemon.ConversationSummary, identity: CloudIdentity) -> CmuxHomeCore.ConversationSummary {
        struct Request: Encodable {
            let summary: CmuxNextDaemon.ConversationSummary
            let identity: HomeCoreMapping.Identity
        }
        struct Reply: Decodable { let summary: HomeCoreMapping.SummaryRow }
        return HomeCoreMapping.mappingRule("cloudSummary", Request(summary: summary, identity: .init(identity)), fallback: Reply?.none)?
            .summary.summary ?? HomeCoreMapping.plainSummary(summary, owner: .cloud)
    }

    /// The owner's conversation kind (`group`, `dm`, `chief`); nil for one it does not name.
    static func kind(_ wire: String?) -> CmuxHomeCore.ConversationSummary.Kind? {
        switch wire {
        case "group": .group
        case "dm": .direct
        case "chief": .chief
        default: nil
        }
    }

    /// A conversation known only from its inbox entry (not loaded yet): no
    /// participant names, so a DM shows no peer name until its head arrives.
    static func summary(_ entry: CloudInboxEntry, identity: CloudIdentity) -> CmuxHomeCore.ConversationSummary {
        var participants = [Participant(id: identity.localID, kind: .human, displayName: identity.displayName)]
        if let peer = entry.dmPeer {
            let isAgent = peer.hasPrefix("agent_")
            participants.append(Participant(id: identity.toHome(peer), kind: isAgent ? .agent : .human, displayName: "",
                                            agentClass: isAgent ? .agent : nil))
        }
        let at = HomeCoreMapping.date(entry.lastAt) ?? .distantPast
        // The entry's unread count excludes the user's own messages; the cursor it implies is a floor.
        let cursor = entry.lastSeq - min(entry.lastSeq, entry.unread)
        var summary = CmuxHomeCore.ConversationSummary(id: ConversationID(entry.conversation), owner: .cloud, title: entry.title,
                                                       participants: participants, lastSeq: entry.lastSeq, rev: entry.rev,
                                                       createdAt: at, updatedAt: at, readCursors: [identity.localID: cursor])
        apply(entry, to: &summary)
        return summary
    }

    /// The user-owned inbox fields (pin, mute) over a head; a newer entry also moves `lastSeq`.
    static func apply(_ entry: CloudInboxEntry, to summary: inout CmuxHomeCore.ConversationSummary) {
        summary.pinRank = entry.pinned ? (entry.pinPosition ?? 0) : nil
        summary.muted = entry.muted
        summary.mentionCount = Int(clamping: entry.mentions)
        // A teammate's entry for someone else's shared Chief conversation says group; the head's chief stays.
        if let kind = kind(entry.kind), summary.declaredKind != .chief { summary.declaredKind = kind }
        if entry.lastSeq > summary.lastSeq {
            summary.lastSeq = entry.lastSeq
            if let at = HomeCoreMapping.date(entry.lastAt) { summary.updatedAt = max(summary.updatedAt, at) }
        }
    }

    /// The text parts a cloud op sends (text and work parts only, as on the local owner; `mapping.cloudParts`).
    static func parts(_ parts: [MessagePart], identity: CloudIdentity) -> [ConversationPart] {
        struct Request: Encodable {
            let parts: [MessagePart]
            let plainTexts: [String?]
            let identity: HomeCoreMapping.Identity
        }
        struct Reply: Decodable { let parts: [ConversationPart] }
        let request = Request(parts: parts, plainTexts: HomeCoreMapping.plainTexts(parts), identity: .init(identity))
        return HomeCoreMapping.mappingRule("cloudParts", request, fallback: Reply?.none)?.parts
            ?? parts.map { .text($0.plainText, runs: []) }
    }

    static func address(_ contact: ContactAddress) -> CloudAddress {
        switch contact {
        case .email(let value): .email(value)
        case .phone(let value): .phone(value)
        }
    }

    static func reaction(_ kind: Reaction.Kind) -> ConversationReactionKind {
        switch kind {
        case .tapback(let tapback): .tapback(tapback.rawValue)
        case .emoji(let emoji): .emoji(emoji)
        }
    }
}
