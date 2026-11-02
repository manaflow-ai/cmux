import CMUXAuthCore
import Foundation

/// Localized text of the Teams part of the Accounts screen (Localizable.xcstrings in this module).
extension AccountsStrings {
    static var teamsTitle: String { text("accounts.teams.title", "Teams") }
    static var teamsNew: String { text("accounts.teams.new", "New Team…") }
    static var teamsEmpty: String { text("accounts.teams.empty", "You are not in a team yet. Create one to share Cloud machines and settings.") }
    static var teamsActive: String { text("accounts.teams.active", "Active") }
    static var teamsDetails: String { text("accounts.teams.details", "Details") }
    static var teamsHideDetails: String { text("accounts.teams.hideDetails", "Hide Details") }
    static var teamsLoading: String { text("accounts.teams.loading", "Loading…") }

    static func role(_ role: CMUXTeamRole?) -> String {
        switch role {
        case .admin: text("accounts.teams.role.admin", "Admin")
        case .member: text("accounts.teams.role.member", "Member")
        case nil: text("accounts.teams.role.unknown", "Role unknown")
        }
    }

    // Detail
    static var teamsYourRole: String { text("accounts.teams.fact.role", "Your role") }
    static var teamsMemberCount: String { text("accounts.teams.fact.members", "Members") }
    /// The member count, with the plan's roster cap when it has one (`3 / 5`).
    static func teamsMemberCountValue(_ count: Int, of limit: Int?) -> String {
        guard let limit else { return count.formatted() }
        return "\(count.formatted()) / \(limit.formatted())"
    }
    static var teamsPlan: String { text("accounts.teams.fact.plan", "Plan") }
    /// No plan reads Free; a paid plan shows its product name (Pro, Max, Team), which is not translated.
    static func plan(_ id: String?) -> String {
        guard let id, !id.isEmpty, id.lowercased() != "free" else { return text("accounts.teams.plan.free", "Free") }
        return id.prefix(1).uppercased() + id.dropFirst()
    }
    static var teamsMembers: String { text("accounts.teams.members", "Members") }
    static var teamsYou: String { text("accounts.teams.you", "You") }
    static var teamsUnnamedMember: String { text("accounts.teams.unnamedMember", "Member") }
    static var teamsInvitations: String { text("accounts.teams.invitations", "Pending Invitations") }
    static var teamsNoInvitations: String { text("accounts.teams.noInvitations", "No pending invitations.") }
    static var teamsInviteLink: String { text("accounts.teams.inviteLink", "Invitation") }
    static func teamsExpires(_ date: String) -> String {
        String(format: text("accounts.teams.expires", "Expires %@"), date)
    }
    static var teamsReadOnly: String {
        text("accounts.teams.readOnly", "Only team admins can rename or delete this team.")
    }

    // Rename, create and delete
    static var teamsRename: String { text("accounts.teams.rename", "Rename…") }
    static var teamsRenameTitle: String { text("accounts.teams.renameTitle", "Rename Team") }
    static var teamsSave: String { text("accounts.teams.save", "Save") }
    static var teamsCreateTitle: String { text("accounts.teams.createTitle", "New Team") }
    static var teamsCreateHelp: String {
        text("accounts.teams.createHelp", "You become the team's admin, and it becomes your active team.")
    }
    static var teamsCreate: String { text("accounts.teams.create", "Create Team") }
    static var teamsNamePlaceholder: String { text("accounts.teams.namePlaceholder", "Team name") }
    /// The number is ``CMUXTeamName/maximumLength``.
    static var teamsNameHelp: String { text("accounts.teams.nameHelp", "Up to 64 characters.") }
    static var teamsDelete: String { text("accounts.teams.delete", "Delete Team…") }
    static var teamsDeleteConfirm: String { text("accounts.teams.deleteConfirm", "Delete Team") }
    static func teamsDeleteQuestion(_ name: String) -> String {
        String(format: text("accounts.teams.deleteQuestion",
                            "Delete “%@”? Its members lose access to the team's Cloud machines and settings. This cannot be undone."), name)
    }

    // Outcomes
    static func teamsCreated(_ name: String) -> String {
        String(format: text("accounts.teams.created", "Created “%@”. It is now your active team."), name)
    }
    static func teamsRenamed(_ name: String) -> String {
        String(format: text("accounts.teams.renamed", "Renamed the team to “%@”."), name)
    }
    static func teamsDeleted(_ name: String) -> String {
        String(format: text("accounts.teams.deleted", "Deleted “%@”."), name)
    }
    static func teamsDeletedActive(_ name: String, now active: String) -> String {
        String(format: text("accounts.teams.deletedActive", "Deleted “%1$@”. “%2$@” is now your active team."), name, active)
    }

    // Errors
    /// The number is ``CMUXTeamName/maximumLength``.
    static var teamsErrorName: String { text("accounts.teams.error.name", "Enter a team name of 1 to 64 characters.") }
    static var teamsErrorForbidden: String { text("accounts.teams.error.forbidden", "Only team admins can do this.") }
    static var teamsErrorSubscription: String {
        text("accounts.teams.error.subscription", "This team has an active subscription. Cancel it in Billing, then delete the team.")
    }
    static var teamsErrorNotFound: String { text("accounts.teams.error.notFound", "This team no longer exists.") }
    static var teamsErrorUnavailable: String { text("accounts.teams.error.unavailable", "Could not reach cmux. Try again.") }
    static var teamsErrorBusy: String { text("accounts.teams.error.busy", "Another team change is still running. Try again when it finishes.") }

    /// User-facing text for a team operation failure.
    static func teamMessage(for error: any Error) -> String {
        switch error as? CMUXTeamError {
        case .invalidName?: teamsErrorName
        case .forbidden?: teamsErrorForbidden
        case .subscriptionActive?: teamsErrorSubscription
        case .notFound?: teamsErrorNotFound
        case .signedOut?: errorNotSignedIn
        case .busy?: teamsErrorBusy
        case .unavailable?, nil: teamsErrorUnavailable
        }
    }
}
