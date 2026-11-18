package import Foundation

/// The strings of the Home models (Localizable.xcstrings): the Chief tags, the group and invite
/// outcomes, group info's members header and roles, Leave Group's question, and the first-run
/// Switching card's lines. The views' own strings stay in their target.
package struct HomeModelStrings {
    package init() {}
    /// The bundle of this module's catalog, so a test can read one language's table (`fr.lproj`).
    package static var bundle: Bundle { .l10n }
    /// The main Chief's tag in the list.
    package static var mainChief: String { String(localized: "home.list.chief.main", defaultValue: "Main", bundle: .l10n) }
    /// A Chief that runs on this Mac.
    package static var placeThisMac: String { String(localized: "home.list.chief.thisMac", defaultValue: "This Mac", bundle: .l10n) }
    /// A Chief that runs in the cloud (the Hosted Chief).
    package static var placeCloud: String { String(localized: "home.list.chief.cloud", defaultValue: "Cloud", bundle: .l10n) }
    /// A Chief on a paired server whose name is not known yet.
    package static var placeServer: String { String(localized: "home.list.chief.server", defaultValue: "Paired server", bundle: .l10n) }
    package static func teamInviteAlreadyMember(_ email: String) -> String {
        String(format: String(localized: "home.teamInvite.alreadyMember", defaultValue: "%@ is already in the team.", bundle: .l10n), email)
    }
    package static func teamInviteSendFailed(_ email: String) -> String {
        String(format: String(localized: "home.teamInvite.sendFailed", defaultValue: "The invite email to %@ couldn’t be sent. Try again.",
                              bundle: .l10n), email)
    }
    package static var teamInviteCancelled: String {
        String(localized: "home.teamInvite.cancelled", defaultValue: "The invite was not sent: the dialog was closed.", bundle: .l10n)
    }
    package static var teamInviteNotAllowed: String {
        String(localized: "home.teamInvite.notAllowed", defaultValue: "Only the team’s admins can invite people.", bundle: .l10n)
    }
    /// What the sheet says after a start or an invite; nil when it closes.
    package static func outcome(_ outcome: HomeComposeOutcome) -> String? {
        switch outcome {
        case .opened: nil
        case .invited: String(localized: "home.outcome.invited", defaultValue: "Invite sent.", bundle: .l10n)
        case .notReachable(let name):
            String(format: String(localized: "home.outcome.notReachable",
                                  defaultValue: "You can’t message %@ yet. Invite them by email instead.", bundle: .l10n), name)
        case .rateLimited:
            String(localized: "home.outcome.rateLimited",
                   defaultValue: "You started too many conversations in the last hour. Try again later.", bundle: .l10n)
        case .invalidAddress(let text):
            String(format: String(localized: "home.outcome.invalidAddress", defaultValue: "“%@” is not an email address.",
                                  bundle: .l10n), text)
        case .offline:
            String(localized: "home.outcome.offline", defaultValue: "You’re offline. Nothing was sent.", bundle: .l10n)
        case .cloudUnreachable:
            String(localized: "home.outcome.cloudUnreachable",
                   defaultValue: "cmux Cloud didn’t answer. Check your connection and try again.", bundle: .l10n)
        case .refused(let reason) where reason.isEmpty:
            String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .l10n)
        case .refused(let reason):
            String(format: String(localized: "home.outcome.refused", defaultValue: "That didn’t work: %@", bundle: .l10n), reason)
        }
    }
    /// The Home row menu's item that opens the sheet for a group.
    package static var infoGroupMenu: String { String(localized: "home.info.menu.group", defaultValue: "Group Info…", bundle: .l10n) }
    /// The members list's plain header. `bundle` and `locale` as for ``infoMemberCount(_:bundle:locale:)``.
    package static func infoMembers(bundle: Bundle = HomeModelStrings.bundle, locale: Locale = .current) -> String {
        String(localized: "home.info.members", defaultValue: "Members", bundle: bundle, locale: locale)
    }
    package static var infoRoleOwner: String { String(localized: "home.info.role.owner", defaultValue: "Owner", bundle: .l10n) }
    package static var infoRoleAdmin: String { String(localized: "home.info.role.admin", defaultValue: "Admin", bundle: .l10n) }
    package static var infoRoleReadOnly: String { String(localized: "home.info.role.readOnly", defaultValue: "Read-only", bundle: .l10n) }
    /// A large group's header ("5,000 members"); a plural string, so each locale picks its form for
    /// `count`, and the interpolated count is formatted for `locale`. `bundle` and `locale` default to
    /// this module's catalog in the user's language; a test passes one language's table and its locale.
    package static func infoMemberCount(_ count: Int, bundle: Bundle = HomeModelStrings.bundle, locale: Locale = .current) -> String {
        String(localized: "home.info.memberCount", defaultValue: "\(count) members", bundle: bundle, locale: locale)
    }
    /// What a group action's outcome says; nil when it worked.
    package static func groupOutcome(_ outcome: HomeGroupOutcome) -> String? {
        switch outcome {
        case .done, .queued, .left: nil
        case .notReachable(let name):
            String(format: String(localized: "home.group.outcome.notReachable",
                                  defaultValue: "You can’t add %@ yet. Invite them by email instead.", bundle: .l10n), name)
        case .ownerOnly:
            String(localized: "home.group.outcome.ownerOnly", defaultValue: "Only the group’s owner can remove people.", bundle: .l10n)
        case .forbidden:
            String(localized: "home.group.outcome.forbidden", defaultValue: "You can’t change this group.", bundle: .l10n)
        case .readOnly:
            String(localized: "home.group.outcome.readOnly", defaultValue: "You can only read this group.", bundle: .l10n)
        case .notAGroup:
            String(localized: "home.group.outcome.notAGroup", defaultValue: "Only a group has a name and members to change.",
                   bundle: .l10n)
        case .unknownConversation:
            String(localized: "home.group.outcome.unknownConversation", defaultValue: "That conversation isn’t in your list.",
                   bundle: .l10n)
        case .unknownPerson(let name):
            String(format: String(localized: "home.group.outcome.unknownPerson", defaultValue: "No one named “%@” is in your contacts.",
                                  bundle: .l10n), name)
        case .notAMember(let name):
            String(format: String(localized: "home.group.outcome.notAMember", defaultValue: "%@ isn’t in this conversation.",
                                  bundle: .l10n), name)
        case .cannotMute:
            String(localized: "home.group.outcome.cannotMute", defaultValue: "Alerts can be hidden only in Cloud conversations.",
                   bundle: .l10n)
        case .emptyText:
            String(localized: "home.group.outcome.emptyText", defaultValue: "Type a message first.", bundle: .l10n)
        case .noPeople:
            String(localized: "home.group.outcome.noPeople", defaultValue: "Choose at least one person.", bundle: .l10n)
        case .offline:
            String(localized: "home.outcome.offline", defaultValue: "You’re offline. Nothing was sent.", bundle: .l10n)
        case .rateLimited:
            String(localized: "home.group.outcome.rateLimited", defaultValue: "Too many changes at once. Try again later.",
                   bundle: .l10n)
        case .tooMany:
            String(localized: "home.group.outcome.tooMany", defaultValue: "A group can have up to 64 people.", bundle: .l10n)
        case .refused:
            // A raw owner code is never shown.
            String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .l10n)
        }
    }
    /// A refused invite's reason as the user reads it (the owner's codes). A code with no
    /// sentence of its own reads as the generic failure: a raw code is never shown.
    package static func inviteRefusal(_ code: String) -> String {
        switch code {
        case "invite.blocked", "invite.recipient_limited":
            String(localized: "home.outcome.inviteBlocked", defaultValue: "This address can’t be invited right now.", bundle: .l10n)
        case "invite.rate_limited":
            String(localized: "home.outcome.inviteRateLimited", defaultValue: "You sent too many invites. Try again later.",
                   bundle: .l10n)
        case "home.not_configured":
            String(localized: "home.outcome.inviteUnavailable", defaultValue: "Invites aren’t available on this server.",
                   bundle: .l10n)
        default:
            String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .l10n)
        }
    }
    package static func leaveTitle(_ name: String) -> String {
        String(format: String(localized: "home.info.leave.title", defaultValue: "Leave “%@”?", bundle: .l10n), name)
    }
    package static var leaveBody: String {
        String(localized: "home.info.leave.body",
               defaultValue: "You stop getting its messages. Someone in the group can add you again.", bundle: .l10n)
    }
    package static var leaveButton: String { String(localized: "home.info.leave.button", defaultValue: "Leave", bundle: .l10n) }

    // MARK: First-run Switching card (``HomeSwitchKeys``)

    package static var switchKeysTabs: String {
        String(localized: "home.firstRun.switchKeys.tabs", defaultValue: "Tab 1–9", bundle: .l10n)
    }
    package static var switchKeysWorkspaces: String {
        String(localized: "home.firstRun.switchKeys.workspaces", defaultValue: "Workspace 1–9", bundle: .l10n)
    }
    package static var switchKeysNextTab: String {
        String(localized: "home.firstRun.switchKeys.nextTab", defaultValue: "Previous / next tab", bundle: .l10n)
    }
    package static var switchKeysNextWorkspace: String {
        String(localized: "home.firstRun.switchKeys.nextWorkspace", defaultValue: "Previous / next workspace", bundle: .l10n)
    }
    package static var switchKeysFocus: String {
        String(localized: "home.firstRun.switchKeys.focus", defaultValue: "Focus back / forward", bundle: .l10n)
    }
}

extension HomeGroupInfo {
    /// The Home row menu's "Group Info…" item.
    public static var groupInfoMenuTitle: String { HomeModelStrings.infoGroupMenu }

    /// The question Leave Group asks first: its title, its text and the button that leaves.
    public var leavePrompt: (title: String, body: String, button: String) {
        (HomeModelStrings.leaveTitle(displayTitle), HomeModelStrings.leaveBody, HomeModelStrings.leaveButton)
    }
}

extension HomeComposeOutcome {
    /// What the sheet (or a refused action) says for this outcome; nil when it closes.
    public var message: String? { HomeModelStrings.outcome(self) }

    /// An invite or op the owner refused with `code`, as the user reads it.
    public static func refusal(code: String) -> HomeComposeOutcome { .refused(HomeModelStrings.inviteRefusal(code)) }
}
