import Foundation

/// Wire types of `/api/teams/[teamId]`. Field names follow the JSON contract
/// in `docs/team-settings-and-invites.md`; see the web `TeamDetail` type.
public enum CloudTeamRole: String, Codable, Sendable, CaseIterable {
    case admin
    case member
}

public struct CloudTeamViewerPermissions: Codable, Equatable, Sendable {
    public var updateTeam: Bool
    public var deleteTeam: Bool
    public var inviteMembers: Bool
    public var readMembers: Bool
    public var removeMembers: Bool
    public var manageApiKeys: Bool
    public var manageBilling: Bool

    public init(
        updateTeam: Bool = false,
        deleteTeam: Bool = false,
        inviteMembers: Bool = false,
        readMembers: Bool = false,
        removeMembers: Bool = false,
        manageApiKeys: Bool = false,
        manageBilling: Bool = false
    ) {
        self.updateTeam = updateTeam
        self.deleteTeam = deleteTeam
        self.inviteMembers = inviteMembers
        self.readMembers = readMembers
        self.removeMembers = removeMembers
        self.manageApiKeys = manageApiKeys
        self.manageBilling = manageBilling
    }
}

public struct CloudTeamMember: Codable, Equatable, Identifiable, Sendable {
    public var userId: String
    public var displayName: String?
    public var email: String?
    public var profileImageUrl: String?
    public var role: CloudTeamRole
    public var isViewer: Bool

    public var id: String { userId }

    public init(
        userId: String,
        displayName: String? = nil,
        email: String? = nil,
        profileImageUrl: String? = nil,
        role: CloudTeamRole,
        isViewer: Bool = false
    ) {
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.profileImageUrl = profileImageUrl
        self.role = role
        self.isViewer = isViewer
    }

    /// The best label for a roster row: team display name, then email, then id.
    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, !email.isEmpty { return email }
        return userId
    }
}

public struct CloudTeamInvitation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var email: String?
    public var role: CloudTeamRole
    public var expiresAt: Date

    public init(id: String, email: String?, role: CloudTeamRole, expiresAt: Date) {
        self.id = id
        self.email = email
        self.role = role
        self.expiresAt = expiresAt
    }
}

public struct CloudTeamInviteLink: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var role: CloudTeamRole
    public var createdAt: Date
    public var createdByUserId: String
    public var expiresAt: Date?
    public var maxUses: Int?
    public var useCount: Int

    public init(
        id: String,
        role: CloudTeamRole = .member,
        createdAt: Date,
        createdByUserId: String,
        expiresAt: Date? = nil,
        maxUses: Int? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.createdByUserId = createdByUserId
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.useCount = useCount
    }
}

public struct CloudTeamBillingSummary: Codable, Equatable, Sendable {
    public var planId: String?
    public var seats: Int?
    /// Roster cap of a personal (Pro/Max) plan, the owner included. `nil`
    /// when the team is uncapped (Team plan or no plan).
    public var memberLimit: Int?
    public var memberCount: Int
    public var hasActiveSubscription: Bool

    public init(planId: String?, seats: Int?, memberLimit: Int?, memberCount: Int, hasActiveSubscription: Bool) {
        self.planId = planId
        self.seats = seats
        self.memberLimit = memberLimit
        self.memberCount = memberCount
        self.hasActiveSubscription = hasActiveSubscription
    }
}

public struct CloudTeamDetail: Codable, Equatable, Sendable {
    public struct Team: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var profileImageUrl: String?

        public init(id: String, displayName: String, profileImageUrl: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.profileImageUrl = profileImageUrl
        }
    }

    public struct Viewer: Codable, Equatable, Sendable {
        public var userId: String
        public var role: CloudTeamRole
        public var permissions: CloudTeamViewerPermissions

        public init(userId: String, role: CloudTeamRole, permissions: CloudTeamViewerPermissions) {
            self.userId = userId
            self.role = role
            self.permissions = permissions
        }
    }

    public var team: Team
    public var viewer: Viewer
    public var members: [CloudTeamMember]
    public var invitations: [CloudTeamInvitation]
    public var links: [CloudTeamInviteLink]
    public var billing: CloudTeamBillingSummary

    public init(
        team: Team,
        viewer: Viewer,
        members: [CloudTeamMember],
        invitations: [CloudTeamInvitation],
        links: [CloudTeamInviteLink],
        billing: CloudTeamBillingSummary
    ) {
        self.team = team
        self.viewer = viewer
        self.members = members
        self.invitations = invitations
        self.links = links
        self.billing = billing
    }

    /// Whether the viewer may invite: admin role plus the invite permission.
    public var canInvite: Bool {
        viewer.role == .admin && viewer.permissions.inviteMembers
    }

    /// Seats still open under a personal-plan cap; `nil` when uncapped.
    /// Pending invitations hold a seat, matching the server rule.
    public var openSeats: Int? {
        guard let limit = billing.memberLimit else { return nil }
        return max(0, limit - members.count - invitations.count)
    }
}

public struct CloudTeamInviteResult: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var email: String
        public var code: String

        public init(email: String, code: String) {
            self.email = email
            self.code = code
        }
    }

    public var invitations: [CloudTeamInvitation]
    public var failed: [Failure]

    public init(invitations: [CloudTeamInvitation], failed: [Failure]) {
        self.invitations = invitations
        self.failed = failed
    }
}

public struct CloudTeamInviteLinkCreated: Codable, Equatable, Sendable {
    public var link: CloudTeamInviteLink
    public var url: String

    public init(link: CloudTeamInviteLink, url: String) {
        self.link = link
        self.url = url
    }
}

/// Failures of ``TeamsClient``. API refusals keep the server's error code so
/// UI, socket and CLI callers map one code to one message.
public enum TeamsClientError: Error, Equatable, Sendable {
    case notSignedIn
    case sessionRefreshFailed
    case invalidIdentifier
    case invalidEmail
    case invalidLinkOptions
    case backendUnreachable(detail: String)
    case malformedResponse(String)
    /// `{ error: { code, message } }` from the team API.
    case api(code: String, status: Int, message: String)

    static func from(status: Int, body: Data) -> TeamsClientError {
        struct Envelope: Decodable {
            struct Inner: Decodable { let code: String; let message: String? }
            let error: Inner
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
            return .api(code: envelope.error.code, status: status, message: envelope.error.message ?? envelope.error.code)
        }
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .api(code: "http_\(status)", status: status, message: text.isEmpty ? "HTTP \(status)" : text)
    }

    /// The server's error code when this is an API refusal.
    public var apiCode: String? {
        if case let .api(code, _, _) = self { return code }
        return nil
    }
}
