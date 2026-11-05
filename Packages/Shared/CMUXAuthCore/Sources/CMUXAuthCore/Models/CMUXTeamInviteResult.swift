import Foundation

/// What `POST /api/teams/:id/invitations` answered: the invitations it sent and each address it
/// did not.
///
/// The server emails each sent invitation itself (Resend). An address already in the team, or
/// one whose email could not be sent, is in ``failed`` with its code; nothing pending exists for it.
public struct CMUXTeamInviteResult: Decodable, Equatable, Sendable {
    /// One address the server sent no invitation to.
    public struct Failure: Decodable, Equatable, Sendable {
        /// The address as the server read it (trimmed).
        public let email: String
        /// Why: `already_member`, or `invite_failed` (the email could not be sent).
        public let code: String

        /// - Parameters:
        ///   - email: The address.
        ///   - code: The server's reason code.
        public init(email: String, code: String) {
            self.email = email
            self.code = code
        }

        /// Whether the address already belongs to a member of the team.
        public var isAlreadyMember: Bool { code == "already_member" }
    }

    /// The invitations sent, each pending until its person accepts.
    public let invitations: [CMUXTeamDetail.Invitation]
    /// The addresses that got no invitation.
    public let failed: [Failure]

    /// - Parameters:
    ///   - invitations: The invitations sent.
    ///   - failed: The addresses that got none.
    public init(invitations: [CMUXTeamDetail.Invitation], failed: [Failure]) {
        self.invitations = invitations
        self.failed = failed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invitations = try container.decodeIfPresent([CMUXTeamDetail.Invitation].self, forKey: .invitations) ?? []
        failed = try container.decodeIfPresent([Failure].self, forKey: .failed) ?? []
    }

    private enum CodingKeys: String, CodingKey { case invitations, failed }
}
