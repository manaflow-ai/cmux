import Foundation

/// Text of the team invite (`team.invite`): the confirmation panel, its
/// refusals and the done toast. Keys live in this module's Localizable.xcstrings.
nonisolated enum TeamInviteStrings {
    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }

    // MARK: Confirmation panel

    static var title: String { t("teamInvite.consent.title", "Send a team invite?") }
    static func lead(team: String) -> String {
        String(format: t("teamInvite.consent.lead",
                         "This emails an invite to join the team “%@”. When someone accepts, the team gains a member, which can raise its bill."), team)
    }
    static var requestedBy: String { t("teamInvite.consent.requestedBy", "Requested by") }
    static var reasonLabel: String { t("teamInvite.consent.reason", "Reason") }
    static var noReason: String { t("teamInvite.consent.noReason", "No reason given.") }
    static var toLabel: String { t("teamInvite.consent.to", "To") }
    static var teamLabel: String { t("teamInvite.consent.team", "Team") }
    static var roleLabel: String { t("teamInvite.consent.role", "Role") }
    static var roleMember: String { t("teamInvite.consent.roleMember", "Member") }
    static var roleAdmin: String { t("teamInvite.consent.roleAdmin", "Admin") }
    static var showAgentChat: String { t("teamInvite.consent.showChat", "Show Agent Chat") }
    static var showTerminal: String { t("teamInvite.consent.showTerminal", "Show Terminal") }
    static var send: String { t("teamInvite.consent.send", "Send Invite") }
    static var deny: String { t("teamInvite.consent.deny", "Don’t Send") }
    static func deadline(_ seconds: Int) -> String {
        String(format: t("teamInvite.consent.deadline", "Closes in %lld s"), seconds)
    }
    static func agentChat(_ name: String) -> String { String(format: t("teamInvite.requester.agentChat", "Agent chat “%@”"), name) }
    static func terminal(_ name: String) -> String { String(format: t("teamInvite.requester.terminal", "Terminal “%@”"), name) }
    static var unknownRequester: String { t("teamInvite.requester.unknown", "A script or app outside cmux") }

    // MARK: Refusals

    static var missingEmail: String { t("teamInvite.error.missingEmail", "Give the address to invite with --email.") }
    static func badEmail(_ text: String) -> String {
        String(format: t("teamInvite.error.badEmail", "“%@” is not an email address."), text)
    }
    static func tooManyEmails(_ count: Int) -> String {
        String(format: t("teamInvite.error.tooManyEmails", "Invite at most %lld addresses at once."), count)
    }
    static func badRole(_ text: String) -> String {
        String(format: t("teamInvite.error.badRole", "“%@” is not a role. Use member or admin."), text)
    }
    static var reasonRequired: String { t("teamInvite.error.reasonRequired", "An agent must say why with --reason.") }
    static var notSignedIn: String { t("teamInvite.error.notSignedIn", "Sign in to cmux in the cmux app first.") }
    static var busy: String { t("teamInvite.error.busy", "Another team invite is waiting for an answer.") }
    static var noWindow: String { t("teamInvite.error.noWindow", "Open a cmux window first, so you can confirm the invite.") }
    static var denied: String { t("teamInvite.error.denied", "The invite was not sent: you chose Don’t Send.") }
    static var timedOut: String { t("teamInvite.error.timedOut", "The invite was not sent: nobody answered in time.") }
    static func notFound(_ name: String, known: String) -> String {
        String(format: t("teamInvite.error.notFound", "No team “%1$@”. Your teams: %2$@."), name, known)
    }
    static func ambiguous(_ known: String) -> String {
        String(format: t("teamInvite.error.ambiguous", "Name the team with --team. Your teams: %@."), known)
    }
    static var noTeams: String { t("teamInvite.error.noTeams", "You are not in a shared team. Create one at cmux.com first.") }
    static func alreadyMember(_ emails: String) -> String {
        String(format: t("teamInvite.error.alreadyMember", "Already in the team: %@."), emails)
    }
    static func failed(_ emails: String) -> String {
        String(format: t("teamInvite.error.failed", "cmux.com could not send the invite to %@."), emails)
    }

    // MARK: Done

    static func sent(_ emails: String, team: String) -> String {
        String(format: t("teamInvite.done", "Invite sent to %1$@ for “%2$@”."), emails, team)
    }
}
