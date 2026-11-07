import Foundation

/// A team invitation addressed to one of the signed-in user's verified emails
/// (`GET /api/teams/invitations`). The verified email is the proof: accepting
/// it needs no emailed token.
public struct CMUXReceivedTeamInvitation: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    /// The team the invitation joins.
    public let teamID: String
    public let teamName: String
    /// The verified address it was sent to.
    public let email: String
    /// The role on joining; nil for a role this client does not know.
    public let role: CMUXTeamRole?
    /// The inviter's name or address, when the server could read it.
    public let invitedBy: String?
    /// ISO 8601, as the server sent it.
    public let expiresAt: String

    public init(id: String, teamID: String, teamName: String, email: String, role: CMUXTeamRole?,
                invitedBy: String?, expiresAt: String) {
        self.id = id
        self.teamID = teamID
        self.teamName = teamName
        self.email = email
        self.role = role
        self.invitedBy = invitedBy
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        teamID = try container.decode(String.self, forKey: .teamId)
        teamName = try container.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CMUXTeamRole.init(rawValue:))
        invitedBy = try container.decodeIfPresent(String.self, forKey: .invitedBy)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, teamId, teamName, email, role, invitedBy, expiresAt }
}

/// What accepting a received invitation answered: the team joined and the role in it.
public struct CMUXTeamJoin: Decodable, Equatable, Sendable {
    public let teamID: String
    public let role: CMUXTeamRole?

    public init(teamID: String, role: CMUXTeamRole?) {
        self.teamID = teamID
        self.role = role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teamID = try container.decode(String.self, forKey: .teamId)
        role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CMUXTeamRole.init(rawValue:))
    }

    private enum CodingKeys: String, CodingKey { case teamId, role }
}
