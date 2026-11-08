import Foundation

/// What the Team section and the `cloud team-*` actions say. Keys live in
/// Resources/CloudTeam.xcstrings with every app locale.
public struct CloudTeamStrings {
    public init() {}

    public static var sectionTitle: String { t("cloudTeam.section.title", "Team") }

    public static func filterTitle(_ filter: CloudTeamSessionStore.Filter) -> String {
        switch filter {
        case .mine: t("cloudTeam.filter.mine", "Assigned to Me")
        case .team: t("cloudTeam.filter.team", "Team")
        case .following: t("cloudTeam.filter.following", "Following")
        case .archived: t("cloudTeam.filter.archived", "Archived")
        }
    }

    public static func empty(_ filter: CloudTeamSessionStore.Filter) -> String {
        switch filter {
        case .mine: t("cloudTeam.empty.mine", "Nothing is assigned to you.")
        case .team: t("cloudTeam.empty.team", "Your team has no Cloud sessions yet.")
        case .following: t("cloudTeam.empty.following", "You are not following any sessions.")
        case .archived: t("cloudTeam.empty.archived", "No archived sessions.")
        }
    }

    public static var follow: String { t("cloudTeam.follow", "Follow") }
    public static var unfollow: String { t("cloudTeam.unfollow", "Unfollow") }
    public static var reassign: String { t("cloudTeam.reassign", "Reassign To") }
    public static var copyLink: String { t("cloudTeam.copyLink", "Copy Link") }
    public static var archive: String { t("cloudTeam.archive", "Archive") }
    public static var restore: String { t("cloudTeam.restore", "Restore") }
    public static var loading: String { t("cloudTeam.loading", "Loading…") }
    public static var noMembers: String { t("cloudTeam.noMembers", "No other members") }

    public static func assignedTo(_ name: String) -> String {
        String(format: t("cloudTeam.assignedTo", "Assigned to %@"), name)
    }

    public static func activity(_ activity: String, machine: String) -> String {
        switch machine {
        case "asleep": return t("cloudTeam.machine.asleep", "Machine asleep")
        case "waking": return t("cloudTeam.machine.waking", "Machine waking")
        case "unresponsive": return t("cloudTeam.machine.unresponsive", "Machine not responding")
        case "gone": return t("cloudTeam.machine.gone", "Machine deleted")
        default: break
        }
        switch activity {
        case "working": return t("cloudTeam.activity.working", "Working")
        case "needs_attention": return t("cloudTeam.activity.needsAttention", "Needs attention")
        default: return t("cloudTeam.activity.idle", "Idle")
        }
    }

    public static var signedOut: String { t("cloudTeam.error.signedOut", "Sign in to cmux to see your team's Cloud sessions.") }
    public static var unreachable: String { t("cloudTeam.error.unreachable", "The Cloud service did not answer. Try again.") }
    public static var notCloud: String {
        t("cloudTeam.error.notCloud", "Name a team Cloud session with --session, or run this from a Cloud workspace or chat.")
    }
    public static var invalidSession: String { t("cloudTeam.error.invalidSession", "That is not a team Cloud session key or link.") }
    public static var attachUnavailable: String {
        t("cloudTeam.error.attachUnavailable", "Opening a teammate's Cloud session here is not available yet. Ask its owner to share the chat with you.")
    }
    public static var notMember: String { t("cloudTeam.error.notMember", "You are not a member of this session's team.") }
    public static var gone: String { t("cloudTeam.error.gone", "This Cloud session was closed or removed.") }
    public static var notOpenHere: String {
        t("cloudTeam.error.notOpenHere", "This session's machine is not connected on this Mac. Connect to the machine, then open the link again.")
    }
    public static var memberRequired: String { t("cloudTeam.error.memberRequired", "Name the member with --to (a user id from cmux cloud team-members).") }
    public static var groupRequired: String { t("cloudTeam.error.groupRequired", "Name the cloud group with --group and the member with --user.") }

    public static func refused(_ code: String) -> String {
        String(format: t("cloudTeam.error.refused", "The Cloud service refused this (%@)."), code)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "CloudTeam", bundle: .module)
    }
}
