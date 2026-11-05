public import CmuxHomeCore
public import Foundation

/// A person the user can message from New Message: a member of the user's
/// team (TeamDO) or a connected person (a DM both of them wrote in).
public struct HomeContact: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        case team
        case connection
        /// One of the user's Chiefs (its conversation is a DM with it).
        case agent
    }

    public let id: ParticipantID
    public var name: String
    public var source: Source

    public init(id: ParticipantID, name: String, source: Source) {
        self.id = id
        self.name = name
        self.source = source
    }

    /// The people of the user's DMs (accepted, not invited), for New
    /// Message's list: each DM peer once, newest DM first.
    public static func connections(in rows: [InboxRow], me: ParticipantID) -> [HomeContact] {
        var seen: Set<ParticipantID> = []
        var result: [HomeContact] = []
        for row in rows where row.kind == .direct {
            guard let peer = row.summary.participants.first(where: { $0.id != me }), peer.kind == .human,
                  peer.membership == .active, !peer.displayName.isEmpty, seen.insert(peer.id).inserted else { continue }
            result.append(HomeContact(id: peer.id, name: peer.displayName, source: .connection))
        }
        return result
    }

    /// Team members first (by name), then connections not in the team,
    /// then the user's Chiefs (`agents`) not listed yet.
    public static func merged(team: [HomeContact], connections: [HomeContact], agents: [HomeContact] = []) -> [HomeContact] {
        let members = team.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var ids = Set(members.map(\.id))
        let people = connections.filter { ids.insert($0.id).inserted }
        return members + people + agents.filter { ids.insert($0.id).inserted }
    }

    /// The user's Chiefs and agents with a one-to-one conversation, each
    /// once, newest conversation first (New Message suggests them by name).
    public static func agents(in rows: [InboxRow], me: ParticipantID) -> [HomeContact] {
        var seen: Set<ParticipantID> = []
        var result: [HomeContact] = []
        for row in rows where row.kind == .chief {
            for peer in row.summary.participants where peer.id != me && peer.kind == .agent && !peer.visibleName.isEmpty {
                guard seen.insert(peer.id).inserted else { continue }
                result.append(HomeContact(id: peer.id, name: peer.visibleName, source: .agent))
            }
        }
        return result
    }
}

/// One recipient of New Message: someone the user reaches, or an address
/// that gets an invite.
public enum HomeRecipient: Hashable, Sendable {
    case contact(HomeContact)
    case address(ContactAddress)

    public var label: String {
        switch self {
        case .contact(let contact): contact.name
        case .address(let address): address.description
        }
    }
}

/// What starting a conversation or sending an invite ended with.
public enum HomeComposeOutcome: Hashable, Sendable {
    /// The conversation exists; the page shows it.
    case opened(ConversationID)
    /// The invite went out (in its own DM when the owner made one).
    case invited(ConversationID?)
    /// The owner refused a person the user cannot reach (`not_reachable`);
    /// the sheet offers an invite by email.
    case notReachable(String)
    /// Too many conversations started in the last hour.
    case rateLimited
    /// The text is not an email address.
    case invalidAddress(String)
    /// The owner is offline: nothing was sent.
    case offline
    /// Sent, but cmux Cloud did not answer (`HomeSendState`): the store may
    /// still resend it, so this never says nothing was sent.
    case cloudUnreachable
    /// Refused for another reason, shown as is.
    case refused(String)
}
