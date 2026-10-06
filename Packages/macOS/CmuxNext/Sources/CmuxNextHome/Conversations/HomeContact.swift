public import CmuxHomeCore
public import Foundation

/// A person the user can message from New Message: a member of the user's
/// team (TeamDO) or a connected person (a DM both of them wrote in).
public struct HomeContact: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        case team
        case connection
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

    /// Team members first (by name), then connections not in the team.
    public static func merged(team: [HomeContact], connections: [HomeContact]) -> [HomeContact] {
        let members = team.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ids = Set(members.map(\.id))
        return members + connections.filter { !ids.contains($0.id) }
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
    /// People and email addresses in one group: invite the addresses first.
    case mixedRecipients
    /// The text is not an email address.
    case invalidAddress(String)
    /// The owner is offline: nothing was sent.
    case offline
    /// Refused for another reason, shown as is.
    case refused(String)
}
