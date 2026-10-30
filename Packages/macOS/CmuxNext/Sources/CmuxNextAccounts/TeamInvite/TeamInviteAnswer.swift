/// The person's answer to a team invite confirmation.
public nonisolated enum TeamInviteAnswer: Sendable, Equatable {
    /// Send the invite.
    case allow
    /// Do not send it.
    case deny
    /// No answer within the confirmation's limit; treated as Deny.
    case timedOut
}
