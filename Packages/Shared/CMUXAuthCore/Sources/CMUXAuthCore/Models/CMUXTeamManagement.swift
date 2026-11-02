import Foundation

/// The signed-in user's role in a team, as the cmux team API (`/api/teams`) reports it.
public enum CMUXTeamRole: String, Codable, Equatable, Sendable {
    case admin
    case member
}

/// What the signed-in user may do in a team (`viewer.permissions` of the team API).
public struct CMUXTeamPermissions: Codable, Equatable, Sendable {
    public var updateTeam: Bool
    public var deleteTeam: Bool
    public var inviteMembers: Bool
    public var readMembers: Bool
    public var removeMembers: Bool
    public var manageApiKeys: Bool
    public var manageBilling: Bool

    public init(updateTeam: Bool = false, deleteTeam: Bool = false, inviteMembers: Bool = false, readMembers: Bool = false,
                removeMembers: Bool = false, manageApiKeys: Bool = false, manageBilling: Bool = false) {
        self.updateTeam = updateTeam
        self.deleteTeam = deleteTeam
        self.inviteMembers = inviteMembers
        self.readMembers = readMembers
        self.removeMembers = removeMembers
        self.manageApiKeys = manageApiKeys
        self.manageBilling = manageBilling
    }

    public init(from decoder: any Decoder) throws {
        // A permission the server does not send is not granted.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)) == true }
        self.init(updateTeam: flag(.updateTeam), deleteTeam: flag(.deleteTeam), inviteMembers: flag(.inviteMembers),
                  readMembers: flag(.readMembers), removeMembers: flag(.removeMembers), manageApiKeys: flag(.manageApiKeys),
                  manageBilling: flag(.manageBilling))
    }
}

/// One team of the signed-in user with the user's role in it. `role` and
/// `permissions` are nil when the role is unknown: the list came from the
/// sign-in service alone, which does not report roles.
public struct CMUXTeamMembership: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let profileImageURL: String?
    public let role: CMUXTeamRole?
    public let permissions: CMUXTeamPermissions?

    public init(id: String, displayName: String, profileImageURL: String? = nil, role: CMUXTeamRole?,
                permissions: CMUXTeamPermissions?) {
        self.id = id
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.role = role
        self.permissions = permissions
    }

    /// A membership whose role is unknown (sign-in-service-only lists).
    public init(team: CMUXAuthTeam) {
        self.init(id: team.id, displayName: team.displayName, role: nil, permissions: nil)
    }

    /// The team summary the rest of the app uses.
    public var team: CMUXAuthTeam { CMUXAuthTeam(id: id, displayName: displayName) }

    /// Whether the user may rename the team: the server requires an admin with the permission.
    public var canRename: Bool { role == .admin && permissions?.updateTeam == true }
    /// Whether the user may delete the team: the server requires an admin with the permission.
    public var canDelete: Bool { role == .admin && permissions?.deleteTeam == true }
}

/// The signed-in user's teams with roles, and the account's selected team.
public struct CMUXTeamMemberships: Equatable, Sendable {
    public let teams: [CMUXTeamMembership]
    public let selectedTeamID: String?

    public init(teams: [CMUXTeamMembership], selectedTeamID: String?) {
        self.teams = teams
        self.selectedTeamID = selectedTeamID
    }

    /// Whether the roles are known (the list came from the cmux team API).
    public var rolesKnown: Bool { teams.allSatisfy { $0.role != nil } }
}

/// One team as its detail page shows it (`GET /api/teams/:id`).
public struct CMUXTeamDetail: Decodable, Equatable, Sendable {
    public struct Team: Decodable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let profileImageUrl: String?

        public init(id: String, displayName: String, profileImageUrl: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.profileImageUrl = profileImageUrl
        }
    }

    public struct Viewer: Decodable, Equatable, Sendable {
        public let userId: String
        public let role: CMUXTeamRole?
        public let permissions: CMUXTeamPermissions

        public init(userId: String, role: CMUXTeamRole?, permissions: CMUXTeamPermissions) {
            self.userId = userId
            self.role = role
            self.permissions = permissions
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userId = try container.decode(String.self, forKey: .userId)
            role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CMUXTeamRole.init(rawValue:))
            permissions = try container.decodeIfPresent(CMUXTeamPermissions.self, forKey: .permissions) ?? CMUXTeamPermissions()
        }

        private enum CodingKeys: String, CodingKey { case userId, role, permissions }
    }

    public struct Member: Decodable, Equatable, Identifiable, Sendable {
        public let userId: String
        public let displayName: String?
        public let email: String?
        public let profileImageUrl: String?
        public let role: CMUXTeamRole?
        public let isViewer: Bool

        public var id: String { userId }

        public init(userId: String, displayName: String?, email: String?, profileImageUrl: String? = nil,
                    role: CMUXTeamRole?, isViewer: Bool) {
            self.userId = userId
            self.displayName = displayName
            self.email = email
            self.profileImageUrl = profileImageUrl
            self.role = role
            self.isViewer = isViewer
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userId = try container.decode(String.self, forKey: .userId)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            profileImageUrl = try container.decodeIfPresent(String.self, forKey: .profileImageUrl)
            role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CMUXTeamRole.init(rawValue:))
            isViewer = try container.decodeIfPresent(Bool.self, forKey: .isViewer) ?? false
        }

        private enum CodingKeys: String, CodingKey { case userId, displayName, email, profileImageUrl, role, isViewer }
    }

    public struct Invitation: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let email: String?
        public let role: CMUXTeamRole?
        /// ISO 8601, as the server sent it.
        public let expiresAt: String

        public init(id: String, email: String?, role: CMUXTeamRole?, expiresAt: String) {
            self.id = id
            self.email = email
            self.role = role
            self.expiresAt = expiresAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            role = (try? container.decodeIfPresent(String.self, forKey: .role)).flatMap { $0 }.flatMap(CMUXTeamRole.init(rawValue:))
            expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case id, email, role, expiresAt }
    }

    public struct Billing: Decodable, Equatable, Sendable {
        public let planId: String?
        public let seats: Int?
        public let memberLimit: Int?
        public let memberCount: Int
        public let hasActiveSubscription: Bool

        public init(planId: String?, seats: Int? = nil, memberLimit: Int? = nil, memberCount: Int, hasActiveSubscription: Bool) {
            self.planId = planId
            self.seats = seats
            self.memberLimit = memberLimit
            self.memberCount = memberCount
            self.hasActiveSubscription = hasActiveSubscription
        }
    }

    public let team: Team
    public let viewer: Viewer
    public let members: [Member]
    public let invitations: [Invitation]
    public let billing: Billing?

    public init(team: Team, viewer: Viewer, members: [Member], invitations: [Invitation], billing: Billing?) {
        self.team = team
        self.viewer = viewer
        self.members = members
        self.invitations = invitations
        self.billing = billing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        team = try container.decode(Team.self, forKey: .team)
        viewer = try container.decode(Viewer.self, forKey: .viewer)
        members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
        invitations = try container.decodeIfPresent([Invitation].self, forKey: .invitations) ?? []
        billing = try? container.decodeIfPresent(Billing.self, forKey: .billing)
    }

    private enum CodingKeys: String, CodingKey { case team, viewer, members, invitations, billing }
}

/// Why a team request failed, from the team API's `{ error: { code } }` and status.
public enum CMUXTeamError: Error, Equatable, Sendable {
    /// Only an admin may do this (403 `forbidden`).
    case forbidden
    /// The team still has an active subscription, so it cannot be deleted (409 `team_has_active_subscription`).
    case subscriptionActive
    /// The team no longer exists, or the user left it (404 or 403 `team_not_found`).
    case notFound
    /// The name is empty or too long (client check, or 400 `invalid_request`).
    case invalidName
    /// No signed-in session to send (or 401).
    case signedOut
    /// Another team change (a switch, a create or a delete) is still running.
    case busy
    /// The service could not answer (network, 5xx, rate limit, an unreadable reply), or this
    /// client has no cmux backend for team management.
    case unavailable

    /// The error for a non-2xx reply: the code first, then the status.
    public init(status: Int, code: String?) {
        switch code {
        case "team_has_active_subscription": self = .subscriptionActive
        case "team_not_found": self = .notFound
        case "forbidden", "last_admin": self = .forbidden
        case "invalid_request": self = .invalidName
        case "unauthorized": self = .signedOut
        default:
            switch status {
            case 401: self = .signedOut
            case 403: self = .forbidden
            case 404: self = .notFound
            default: self = .unavailable
            }
        }
    }
}

/// A team name the person typed, trimmed and checked: 1 to ``maximumLength`` characters.
public struct CMUXTeamName: Equatable, Sendable {
    /// The longest name the Mac's team forms accept.
    public static let maximumLength = 64
    /// The longest name the cmux team API accepts (`web/services/teams/schemas.ts`).
    public static let serverMaximumLength = 120

    public let value: String

    /// - Parameter maximumLength: The longest trimmed name allowed.
    /// - Throws: ``CMUXTeamError/invalidName`` when the trimmed name is empty or too long.
    public init(_ raw: String, maximumLength: Int = CMUXTeamName.maximumLength) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { throw CMUXTeamError.invalidName }
        value = trimmed
    }
}
