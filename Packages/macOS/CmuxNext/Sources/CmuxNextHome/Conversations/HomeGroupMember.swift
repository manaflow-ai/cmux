public import CmuxHomeCore

/// One person (or agent) of a DM or group as the group info sheet lists them.
public struct HomeGroupMember: Hashable, Sendable, Identifiable {
    public let id: ParticipantID
    /// The name a person reads (never an internal id); empty when the owner sent none.
    public var name: String
    /// One or two letters for the monogram avatar.
    public var initials: String
    /// The signed-in user.
    public var isMe: Bool
    /// An agent (a Chief or another agent principal).
    public var isAgent: Bool
    /// Invited by email and not joined yet.
    public var isInvited: Bool

    public init(id: ParticipantID, name: String, initials: String, isMe: Bool, isAgent: Bool, isInvited: Bool) {
        self.id = id
        self.name = name
        self.initials = initials
        self.isMe = isMe
        self.isAgent = isAgent
        self.isInvited = isInvited
    }

    /// The member for `participant`; `me` marks the signed-in user.
    public init(_ participant: Participant, me: ParticipantID?) {
        self.init(id: participant.id, name: participant.visibleName, initials: participant.initials, isMe: participant.id == me,
                  isAgent: participant.kind == .agent, isInvited: participant.membership == .invited)
    }
}
