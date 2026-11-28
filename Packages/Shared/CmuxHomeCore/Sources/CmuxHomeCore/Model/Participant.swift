import Foundation

/// A member of a conversation: a person or an agent principal.
public struct Participant: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case human
        case agent
    }

    /// The agent class from identity-and-permissions (D20). A Chief (and every
    /// subchief, which is the same thing) is the privileged orchestrator class.
    public enum AgentClass: String, Hashable, Sendable, Codable {
        case chief
        case agent
    }

    /// Whether a human has accepted an invite. An invited person can already be
    /// a participant (messages wait for them) before they have an account.
    public enum Membership: String, Hashable, Sendable, Codable {
        case active
        case invited
    }

    public let id: ParticipantID
    public var kind: Kind
    public var displayName: String
    public var agentClass: AgentClass?
    /// The agent's owner (Chiefs belong to one human).
    public var ownerUser: ParticipantID?
    public var membership: Membership
    /// Email or phone the invite went to; only set while `membership == .invited`.
    public var invitedContact: String?

    public init(
        id: ParticipantID,
        kind: Kind,
        displayName: String,
        agentClass: AgentClass? = nil,
        ownerUser: ParticipantID? = nil,
        membership: Membership = .active,
        invitedContact: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.agentClass = agentClass
        self.ownerUser = ownerUser
        self.membership = membership
        self.invitedContact = invitedContact
    }

    public var isChief: Bool { kind == .agent && agentClass == .chief }

    /// One or two letters for a monogram avatar.
    public var initials: String {
        let words = displayName.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
