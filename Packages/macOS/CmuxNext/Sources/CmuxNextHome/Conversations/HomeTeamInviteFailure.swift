/// Why a team invite did not go out, in the words Invite to Team shows (and a CLI or agent run gets).
public enum HomeTeamInviteFailure: Hashable, Sendable {
    /// The address belongs to someone already in the team (the server's `already_member`).
    case alreadyMember(String)
    /// The server could not send the invite email to the address (`invite_failed`).
    case sendFailed(String)
    /// The person may not invite to this team (403).
    case notAllowed
    /// The person closed the dialog without sending.
    case cancelled

    /// The sentence the dialog's status line shows.
    public var message: String {
        switch self {
        case .alreadyMember(let email): HomeConversationStrings.teamInviteAlreadyMember(email)
        case .sendFailed(let email): HomeConversationStrings.teamInviteSendFailed(email)
        case .notAllowed: HomeConversationStrings.teamInviteNotAllowed
        case .cancelled: HomeConversationStrings.teamInviteCancelled
        }
    }
}
