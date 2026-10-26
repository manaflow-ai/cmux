import Foundation
import Observation

/// The signed-in account's role in a team, as the cmux team API reports it.
public enum TeamRole: String, Codable, Hashable, Sendable {
    case admin, member

    /// The role as rows and the team page write it.
    public var title: String {
        switch self {
        case .admin: String(localized: "Admin")
        case .member: String(localized: "Member")
        }
    }
}

/// What the signed-in account may do in a team (`permissions` on the team API).
public struct TeamPermissions: Codable, Hashable, Sendable {
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

    /// Nothing allowed (a member, or permissions not known).
    public static let none = TeamPermissions()
    /// Everything allowed (an admin).
    public static let all = TeamPermissions(updateTeam: true, deleteTeam: true, inviteMembers: true, readMembers: true,
                                            removeMembers: true, manageApiKeys: true, manageBilling: true)

    // A permission the server adds later decodes as false, never as a failure.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? false }
        self.init(updateTeam: flag(.updateTeam), deleteTeam: flag(.deleteTeam), inviteMembers: flag(.inviteMembers),
                  readMembers: flag(.readMembers), removeMembers: flag(.removeMembers), manageApiKeys: flag(.manageApiKeys),
                  manageBilling: flag(.manageBilling))
    }
}

/// One of the account's teams with its role (`GET /api/teams`).
public struct TeamSummary: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let role: TeamRole
    public let permissions: TeamPermissions

    public init(id: String, displayName: String, role: TeamRole, permissions: TeamPermissions) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.permissions = permissions
    }

    public var accountTeam: AppStore.AccountTeam {
        AppStore.AccountTeam(id: id, name: displayName, role: role)
    }
}

/// The account's teams and the server-side selection (`GET /api/teams`).
public struct TeamDirectory: Hashable, Sendable {
    public let teams: [TeamSummary]
    public let selectedTeamID: String?

    public init(teams: [TeamSummary], selectedTeamID: String?) {
        self.teams = teams
        self.selectedTeamID = selectedTeamID
    }
}

/// Everything the team page shows (`GET /api/teams/:id`). Roles are optional:
/// a team read from the sign-in service while the cmux service is unreachable
/// (and the personal space) has members but no roles, and offers no admin actions.
public struct TeamDetail: Hashable, Sendable {
    public struct Member: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let email: String?
        public let role: TeamRole?
        public let isYou: Bool

        public init(id: String, name: String, email: String? = nil, role: TeamRole?, isYou: Bool) {
            self.id = id
            self.name = name
            self.email = email
            self.role = role
            self.isYou = isYou
        }

        public var initials: String {
            let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            return letters.isEmpty ? "?" : letters.uppercased()
        }
    }

    public struct Invitation: Identifiable, Hashable, Sendable {
        public let id: String
        public let email: String?
        public let role: TeamRole
        public let expiresAt: Date?

        public init(id: String, email: String?, role: TeamRole, expiresAt: Date?) {
            self.id = id
            self.email = email
            self.role = role
            self.expiresAt = expiresAt
        }
    }

    public struct Billing: Hashable, Sendable {
        public let planID: String?
        public let seats: Int?
        public let memberLimit: Int?
        public let memberCount: Int
        public let hasActiveSubscription: Bool

        public init(planID: String?, seats: Int? = nil, memberLimit: Int? = nil, memberCount: Int, hasActiveSubscription: Bool) {
            self.planID = planID
            self.seats = seats
            self.memberLimit = memberLimit
            self.memberCount = memberCount
            self.hasActiveSubscription = hasActiveSubscription
        }

        /// The plan's name ("Pro", "Team"), or nil for no plan.
        public var planTitle: String? {
            guard let planID, !planID.isEmpty else { return nil }
            return planID.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }

        /// "3" or "3 of 5" when the plan caps the roster.
        public var memberCountText: String {
            if let memberLimit { return String(localized: "\(memberCount) of \(memberLimit)") }
            return "\(memberCount)"
        }
    }

    public let id: String
    public var name: String
    public let role: TeamRole?
    public let permissions: TeamPermissions
    /// You first, then admins, then by name.
    public let members: [Member]
    /// Pending invitations; the server sends them to admins only.
    public let invitations: [Invitation]
    public let billing: Billing?

    public init(id: String, name: String, role: TeamRole?, permissions: TeamPermissions, members: [Member],
                invitations: [Invitation] = [], billing: Billing? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.permissions = permissions
        self.members = members.sorted { lhs, rhs in
            if lhs.isYou != rhs.isYou { return lhs.isYou }
            if (lhs.role == .admin) != (rhs.role == .admin) { return lhs.role == .admin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        self.invitations = invitations
        self.billing = billing
    }

    public var isAdmin: Bool { role == .admin }
    public var canRename: Bool { isAdmin && permissions.updateTeam }
    public var canDelete: Bool { isAdmin && permissions.deleteTeam }

    /// A team known only from the sign-in service: its members, no roles.
    public static func withoutRoles(id: String, name: String, members: [TeamMember]) -> TeamDetail {
        TeamDetail(id: id, name: name, role: nil, permissions: .none,
                   members: members.map { Member(id: $0.id, name: $0.name, role: nil, isYou: $0.isYou) })
    }
}

/// The team actions the team page needs, behind one seam: the cmux team API
/// in the app, a fake in tests, sample data in DEBUG mock mode.
public protocol TeamManaging: Sendable {
    func team(id: String) async throws -> TeamDetail
    /// Renames the team; returns the name the server stored.
    func renameTeam(id: String, to name: String) async throws -> String
    func deleteTeam(id: String) async throws
}

/// The team page's state and its admin actions (rename, delete). Views read
/// it; the owner hears about changes through `onRenamed` and `onDeleted` and
/// refreshes the team list then (no polling).
@MainActor
@Observable
public final class TeamDetailModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded(TeamDetail)
        case failed(String)
    }

    public let teamID: String
    public private(set) var phase: Phase = .loading
    /// A rename or delete is in flight (its buttons are disabled).
    public private(set) var isWorking = false
    /// Why the last rename or delete failed, in words for the user.
    public var actionError: String?

    @ObservationIgnored private let service: any TeamManaging
    /// The team was renamed: its id and new name.
    @ObservationIgnored public var onRenamed: (@MainActor (String, String) -> Void)?
    /// The team was deleted: its id.
    @ObservationIgnored public var onDeleted: (@MainActor (String) -> Void)?

    public init(teamID: String, service: any TeamManaging) {
        self.teamID = teamID
        self.service = service
    }

    public var detail: TeamDetail? {
        if case .loaded(let detail) = phase { return detail }
        return nil
    }

    /// Loads (or reloads) the team. A shown team stays on screen while it reloads.
    public func load() async {
        if detail == nil { phase = .loading }
        do {
            phase = .loaded(try await service.team(id: teamID))
        } catch is CancellationError {
        } catch {
            if detail == nil { phase = .failed(TeamServiceError.message(for: error, action: .load)) }
        }
    }

    /// Renames the team (admins only). Returns whether it was renamed.
    @discardableResult
    public func rename(to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var detail, detail.canRename, !trimmed.isEmpty, trimmed != detail.name, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        actionError = nil
        do {
            let stored = try await service.renameTeam(id: teamID, to: trimmed)
            detail.name = stored.isEmpty ? trimmed : stored
            phase = .loaded(detail)
            onRenamed?(teamID, detail.name)
            return true
        } catch {
            actionError = TeamServiceError.message(for: error, action: .rename)
            return false
        }
    }

    /// Deletes the team (admins only). Returns whether it was deleted.
    @discardableResult
    public func delete() async -> Bool {
        guard let detail, detail.canDelete, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        actionError = nil
        do {
            try await service.deleteTeam(id: teamID)
            onDeleted?(teamID)
            return true
        } catch {
            actionError = TeamServiceError.message(for: error, action: .delete)
            return false
        }
    }
}

/// Errors from the cmux team API (`{ error: { code, message } }`).
public enum TeamServiceError: Error, Equatable, Sendable {
    /// No answer: offline, the server is down, or no service is configured.
    case unreachable
    /// The server answered with an error.
    case server(status: Int, code: String, message: String)
    /// The answer could not be read.
    case malformed

    public enum Action: Sendable {
        case load, create, rename, delete
    }

    public var code: String? {
        if case .server(_, let code, _) = self { return code }
        return nil
    }

    /// A message for the user. Never the server's English developer message.
    public static func message(for error: any Error, action: Action) -> String {
        let error = error as? TeamServiceError
        switch error?.code {
        case "team_has_active_subscription"?:
            return String(localized: "This team has an active subscription. Cancel it on cmux.com, then delete the team.")
        case "forbidden"?, "last_admin"?:
            return String(localized: "Only team admins can do this.")
        case "team_not_found"?:
            return String(localized: "This team no longer exists.")
        case "unauthorized"?:
            return String(localized: "Your session ended. Sign in again.")
        case "rate_limited"?:
            return String(localized: "Too many requests. Try again in a moment.")
        case "invalid_request"? where action == .rename || action == .create:
            return String(localized: "That team name can't be used. Try another.")
        default:
            break
        }
        if error == .unreachable { return String(localized: "Couldn't reach cmux. Check your connection and try again.") }
        switch action {
        case .load: return String(localized: "Couldn't load the team.")
        case .create: return String(localized: "Couldn't create the team.")
        case .rename: return String(localized: "Couldn't rename the team.")
        case .delete: return String(localized: "Couldn't delete the team.")
        }
    }
}

extension AppStore {
    /// The team list after `teamID` was deleted, and the team to show then: the
    /// one already active when it remains, else the first other team, else the
    /// personal space (the live coordinator adds it to an empty list).
    public func teamsAfterDeleting(_ teamID: String) -> (teams: [AccountTeam], selectedID: String?) {
        let remaining = teams.filter { $0.id != teamID }.map(\.accountTeam)
        if activeTeamID != teamID, remaining.contains(where: { $0.id == activeTeamID }) {
            return (remaining, activeTeamID)
        }
        let next = remaining.first { !$0.id.hasPrefix("personal-") } ?? remaining.first
        return (remaining, next?.id)
    }

    /// A team's new name, applied at once (the server's list follows).
    public func renameTeam(_ teamID: String, to name: String) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }), teams[index].name != name else { return }
        teams[index].name = name
    }
}

extension Team {
    /// The team as the account reports it (id, name, role).
    public var accountTeam: AppStore.AccountTeam {
        AppStore.AccountTeam(id: id, name: name, role: role)
    }
}
