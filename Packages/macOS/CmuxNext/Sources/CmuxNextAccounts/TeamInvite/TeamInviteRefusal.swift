/// Why a team invite run was refused before or instead of sending: its code
/// becomes the control error code (`invalid_params`, `team.not_found`, `team.denied`).
public nonisolated struct TeamInviteRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// The control error code.
    public var code: String
    /// The readable reason.
    public var message: String

    /// Creates a refusal.
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Nobody is signed in to cmux in this app, so there is no account to invite as.
    public static var notSignedIn: TeamInviteRefusal {
        TeamInviteRefusal(code: "not_signed_in", message: TeamInviteStrings.notSignedIn)
    }

    /// An agent gave no `--reason`.
    public static var reasonRequired: TeamInviteRefusal {
        TeamInviteRefusal(code: "invalid_params", message: TeamInviteStrings.reasonRequired)
    }

    public var description: String { message }
}
