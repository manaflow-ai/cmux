import Foundation

/// Team roster and invitation values the Settings Team card renders. The host
/// maps its cloud client's wire types into these so the package stays free of
/// the auth and cloud libraries.
public enum AccountTeamRole: String, Sendable, Hashable, CaseIterable {
    case admin
    case member
}

public struct AccountTeamMember: Sendable, Hashable, Identifiable {
    public let userID: String
    public let displayName: String?
    public let email: String?
    public let role: AccountTeamRole
    public let isViewer: Bool

    public var id: String { userID }

    public init(userID: String, displayName: String?, email: String?, role: AccountTeamRole, isViewer: Bool) {
        self.userID = userID
        self.displayName = displayName
        self.email = email
        self.role = role
        self.isViewer = isViewer
    }

    /// Team display name, then email, then id.
    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let email, !email.isEmpty { return email }
        return userID
    }
}

public struct AccountTeamInvitation: Sendable, Hashable, Identifiable {
    public let id: String
    public let email: String?
    public let role: AccountTeamRole
    public let expiresAt: Date

    public init(id: String, email: String?, role: AccountTeamRole, expiresAt: Date) {
        self.id = id
        self.email = email
        self.role = role
        self.expiresAt = expiresAt
    }
}

public struct AccountTeamInviteLink: Sendable, Hashable, Identifiable {
    public let id: String
    public let expiresAt: Date?
    public let maxUses: Int?
    public let useCount: Int

    public init(id: String, expiresAt: Date?, maxUses: Int?, useCount: Int) {
        self.id = id
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.useCount = useCount
    }
}

public struct AccountTeamDetail: Sendable, Hashable {
    public let teamID: String
    public let teamName: String
    public let viewerUserID: String
    public let viewerRole: AccountTeamRole
    /// Admin plus the invite permission.
    public let canInvite: Bool
    public let canRemoveMembers: Bool
    public let members: [AccountTeamMember]
    public let invitations: [AccountTeamInvitation]
    public let links: [AccountTeamInviteLink]
    /// Roster cap of a personal plan, the owner included; nil when uncapped.
    public let memberLimit: Int?

    public init(
        teamID: String,
        teamName: String,
        viewerUserID: String,
        viewerRole: AccountTeamRole,
        canInvite: Bool,
        canRemoveMembers: Bool,
        members: [AccountTeamMember],
        invitations: [AccountTeamInvitation],
        links: [AccountTeamInviteLink],
        memberLimit: Int?
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.viewerUserID = viewerUserID
        self.viewerRole = viewerRole
        self.canInvite = canInvite
        self.canRemoveMembers = canRemoveMembers
        self.members = members
        self.invitations = invitations
        self.links = links
        self.memberLimit = memberLimit
    }

    /// Seats used under a personal-plan cap; pending invitations hold a seat.
    public var seatsUsed: Int { members.count + invitations.count }
}

public struct AccountTeamInviteOutcome: Sendable, Hashable {
    public let sentEmails: [String]
    public let failedEmails: [String]

    public init(sentEmails: [String], failedEmails: [String]) {
        self.sentEmails = sentEmails
        self.failedEmails = failedEmails
    }
}

public struct AccountTeamInviteLinkOutcome: Sendable, Hashable {
    public let url: String
    public let expiresAt: Date?

    public init(url: String, expiresAt: Date?) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Raised by the default ``AccountFlow`` team methods for hosts without team
/// management.
public enum AccountTeamManagementError: Error, Equatable, Sendable {
    case unsupported
}

/// Team roster and invitation actions the Settings Team card drives. Every
/// call applies to the selected team. Hosts implement these on their
/// ``AccountFlow``; the defaults declare the feature unavailable.
@MainActor
public protocol AccountTeamManagement: AnyObject {
    /// Whether the host can manage the selected team's members.
    var supportsTeamManagement: Bool { get }
    func loadTeamDetail() async throws -> AccountTeamDetail
    func inviteTeamMembers(emails: [String], role: AccountTeamRole) async throws -> AccountTeamInviteOutcome
    /// A reusable member-only link that expires after seven days.
    func createTeamInviteLink() async throws -> AccountTeamInviteLinkOutcome
    func revokeTeamInvitation(id: String) async throws
    func revokeTeamInviteLink(id: String) async throws
    /// Remove a member, or leave the team with the viewer's own id.
    func removeTeamMember(userID: String) async throws
    func changeTeamMemberRole(userID: String, role: AccountTeamRole) async throws
    /// One user-facing sentence for a failed team action.
    func teamManagementMessage(for error: Error) -> String
}

extension AccountFlow {
    public var supportsTeamManagement: Bool { false }
    public func loadTeamDetail() async throws -> AccountTeamDetail { throw AccountTeamManagementError.unsupported }
    public func inviteTeamMembers(emails: [String], role: AccountTeamRole) async throws -> AccountTeamInviteOutcome {
        throw AccountTeamManagementError.unsupported
    }
    public func createTeamInviteLink() async throws -> AccountTeamInviteLinkOutcome {
        throw AccountTeamManagementError.unsupported
    }
    public func revokeTeamInvitation(id: String) async throws { throw AccountTeamManagementError.unsupported }
    public func revokeTeamInviteLink(id: String) async throws { throw AccountTeamManagementError.unsupported }
    public func removeTeamMember(userID: String) async throws { throw AccountTeamManagementError.unsupported }
    public func changeTeamMemberRole(userID: String, role: AccountTeamRole) async throws {
        throw AccountTeamManagementError.unsupported
    }
    public func teamManagementMessage(for error: Error) -> String {
        String(localized: "settings.team.error.generic", defaultValue: "Could not update the team. Try again.")
    }
}
