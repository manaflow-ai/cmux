import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Share with Guest's and Invite People's refusals and notices (Resources/AgentShare.xcstrings).
enum AgentShareStrings {
    static var notAChat: String {
        String(localized: "agentShare.notAChat", defaultValue: "Only a started agent chat can be shared.", table: "AgentShare", bundle: .module)
    }

    static var notThisMac: String {
        String(localized: "agentShare.notThisMac", defaultValue: "Only a chat on this Mac can be shared.", table: "AgentShare", bundle: .module)
    }

    static var badSurface: String {
        String(localized: "agentShare.badSurface", defaultValue: "--surface takes a surface number.", table: "AgentShare", bundle: .module)
    }

    static var surfaceAndTarget: String {
        String(localized: "agentShare.surfaceAndTarget", defaultValue: "Name the chat with --surface or with a tab target, not both.", table: "AgentShare", bundle: .module)
    }

    static var badUses: String {
        String(localized: "agentShare.badUses", defaultValue: "--uses takes a number from 1 to 8.", table: "AgentShare", bundle: .module)
    }

    static var timedOut: String {
        String(localized: "agentShare.timedOut", defaultValue: "The share service didn’t answer in time, so no link was made. Try again.", table: "AgentShare", bundle: .module)
    }

    static func noSurface(_ surface: Int) -> String {
        String(format: String(localized: "agentShare.noSurface", defaultValue: "No agent chat is on surface %lld.", table: "AgentShare", bundle: .module), Int64(surface))
    }

    static var badTTL: String {
        String(localized: "agentShare.badTTL", defaultValue: "A link lasts from 1 minute to 7 days: give seconds, or a number with m, h or d (24h).", table: "AgentShare", bundle: .module)
    }

    static var needsShareID: String {
        String(localized: "agentShare.needsShareID", defaultValue: "Name the link's share ID (cmux share list shows it).", table: "AgentShare", bundle: .module)
    }

    static var needsGuestID: String {
        String(localized: "agentShare.needsGuestID", defaultValue: "Name the guest's ID (cmux share list shows it).", table: "AgentShare", bundle: .module)
    }

    static var copied: String {
        String(localized: "agentShare.copied", defaultValue: "Guest link copied. It works once and expires in 24 hours.", table: "AgentShare", bundle: .module)
    }

    static var noRoom: String {
        String(localized: "agentShare.noRoom", defaultValue: "The link was made, but this cmux has no share service to open it.", table: "AgentShare", bundle: .module)
    }

    /// A person's sentence for the daemon's `share.*` refusal; nil keeps the daemon's message.
    static func reason(_ code: String) -> String? {
        switch code {
        case "share.needs_sign_in": String(localized: "agentShare.needsSignIn", defaultValue: "Sign in to cmux to share a chat.", table: "AgentShare", bundle: .module)
        case "share.room_unreachable": String(localized: "agentShare.roomUnreachable", defaultValue: "The share service didn’t answer. Try again in a moment.", table: "AgentShare", bundle: .module)
        case "share.room_refused": String(localized: "agentShare.roomRefused", defaultValue: "Sharing is off for this account.", table: "AgentShare", bundle: .module)
        case "share.not_a_chat": notAChat
        case "share.chat_moved": String(localized: "agentShare.chatMoved", defaultValue: "That surface shows another chat now. Name the chat again.", table: "AgentShare", bundle: .module)
        case "share.limit": String(localized: "agentShare.limit", defaultValue: "This Mac has too many links. Revoke one first.", table: "AgentShare", bundle: .module)
        case "share.unknown": String(localized: "agentShare.unknown", defaultValue: "No such link or guest.", table: "AgentShare", bundle: .module)
        case "share.not_trusted": String(localized: "agentShare.notTrusted", defaultValue: "Only chats on this Mac can be shared.", table: "AgentShare", bundle: .module)
        case "share.invited": alreadyInvited
        case "share.bad_request": String(localized: "agentShare.badRequest", defaultValue: "A link works 1 to 8 times and lasts from 1 minute to 7 days.", table: "AgentShare", bundle: .module)
        default: nil
        }
    }

    /// The owner's consent sheet for a link a run they did not start asks for (#30263).
    static func consentTitle(_ chat: String) -> String {
        String(format: String(localized: "agentShare.consent.title", defaultValue: "Share “%@” with a guest?", table: "AgentShare", bundle: .module), chat)
    }

    static var consentDetail: String {
        String(localized: "agentShare.consent.detail", defaultValue: "An agent or script asked for a guest link to this chat. Anyone with the link sees the chat as you do, including command output and the agent’s reasoning.", table: "AgentShare", bundle: .module)
    }

    /// How long the link lasts and how many times it works, in the sheet's words.
    static func consentTerms(ttlSecs: UInt64, uses: UInt32) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        let lasts = formatter.string(from: TimeInterval(ttlSecs)) ?? "\(ttlSecs)s"
        if uses == 1 {
            return String(format: String(localized: "agentShare.consent.termsOnce", defaultValue: "The link lasts %@ and works once.", table: "AgentShare", bundle: .module), lasts)
        }
        return String(format: String(localized: "agentShare.consent.terms", defaultValue: "The link lasts %1$@ and works %2$lld times.", table: "AgentShare", bundle: .module), lasts, Int64(uses))
    }

    static var consentAllow: String {
        String(localized: "agentShare.consent.allow", defaultValue: "Make Link", table: "AgentShare", bundle: .module)
    }

    /// The share consent's Feed request (Needs you): its button that brings the Mac's sheet forward.
    static var consentShowOnMac: String {
        String(localized: "agentShare.consent.showOnMac", defaultValue: "Show on Mac", table: "AgentShare", bundle: .module)
    }

    static var consentDecline: String {
        String(localized: "agentShare.consent.decline", defaultValue: "Don’t Share", table: "AgentShare", bundle: .module)
    }

    static var declined: String {
        String(localized: "agentShare.declined", defaultValue: "The chat’s owner didn’t allow a guest link, so none was made.", table: "AgentShare", bundle: .module)
    }

    // Invite People (AgentShareInvites.swift).

    static var needsAccount: String {
        String(localized: "agentShare.invite.needsAccount", defaultValue: "Name the person’s cmux account: an email address or @handle.", table: "AgentShare", bundle: .module)
    }

    static var badAccount: String {
        String(localized: "agentShare.invite.badAccount", defaultValue: "That isn’t an email address or a cmux @handle.", table: "AgentShare", bundle: .module)
    }

    static var badRole: String {
        String(localized: "agentShare.invite.badRole", defaultValue: "--role takes view or talk.", table: "AgentShare", bundle: .module)
    }

    /// A person's own invite run, said in place.
    static func invited(_ account: String, role: String) -> String {
        if role == "view" {
            return String(format: String(localized: "agentShare.invite.invitedView", defaultValue: "Invited %@. They can watch this chat once they sign in.", table: "AgentShare", bundle: .module), account)
        }
        return String(format: String(localized: "agentShare.invite.invitedTalk", defaultValue: "Invited %@. Once they sign in they can watch and send messages, each one waiting for you.", table: "AgentShare", bundle: .module), account)
    }

    static func notInvited(_ account: String) -> String {
        String(format: String(localized: "agentShare.invite.notInvited", defaultValue: "%@ isn’t invited to this chat.", table: "AgentShare", bundle: .module), account)
    }

    static var alreadyInvited: String {
        String(localized: "agentShare.invite.alreadyInvited", defaultValue: "They’re already invited with the other access. Remove them first, then invite them again.", table: "AgentShare", bundle: .module)
    }

    /// The owner's consent sheet for an invite a run they did not start asks for (#30263).
    static func inviteConsentTitle(_ account: String, chat: String) -> String {
        String(format: String(localized: "agentShare.invite.consent.title", defaultValue: "Invite %1$@ to “%2$@”?", table: "AgentShare", bundle: .module), account, chat)
    }

    static var inviteConsentDetail: String {
        String(localized: "agentShare.invite.consent.detail", defaultValue: "An agent or script asked to invite this account. Once they sign in, they see the chat as you do, including command output and the agent’s reasoning.", table: "AgentShare", bundle: .module)
    }

    /// What the invited account may do, in the sheet's words.
    static func inviteRoleLine(_ role: String) -> String {
        if role == "view" {
            return String(localized: "agentShare.invite.consent.view", defaultValue: "They can watch, but not send messages.", table: "AgentShare", bundle: .module)
        }
        return String(localized: "agentShare.invite.consent.talk", defaultValue: "They can also send messages. Each one waits for you to approve it.", table: "AgentShare", bundle: .module)
    }

    static var inviteConsentAllow: String {
        String(localized: "agentShare.invite.consent.allow", defaultValue: "Invite", table: "AgentShare", bundle: .module)
    }

    static var inviteConsentDecline: String {
        String(localized: "agentShare.invite.consent.decline", defaultValue: "Don’t Invite", table: "AgentShare", bundle: .module)
    }

    static var inviteDeclined: String {
        String(localized: "agentShare.invite.declined", defaultValue: "The chat’s owner didn’t allow the invite, so nobody was invited.", table: "AgentShare", bundle: .module)
    }

    /// A share verb's failure for its caller: the daemon's `share.*` code (the CLI and MCP see it as
    /// the error code) with a sentence a person can act on.
    static func failure(_ error: any Error) -> ActionWorkFailure {
        // The owner said no, or did not answer: nothing was made, so a retry asks again.
        if let refusal = error as? AgentShareDeclined {
            return ActionWorkFailure(code: "share.declined", reason: refusal.invite ? inviteDeclined : declined)
        }
        if error is AgentShareBadAccount { return ActionWorkFailure(code: "share.bad_request", reason: badAccount) }
        if let missing = error as? AgentShareNotInvited { return ActionWorkFailure(code: "share.not_invited", reason: notInvited(missing.account)) }
        // No answer in time: the daemon may still make (or provision) the share, so the caller is
        // told the run may have applied and must not simply retry.
        if case DaemonError.timedOut = error {
            return ActionWorkFailure(timedOut, mayHaveApplied: true)
        }
        guard case DaemonError.command(_, let message, let code?, _, _) = error, code.hasPrefix("share.") else {
            return ActionWorkFailure(RefusalStrings.describe(error))
        }
        return ActionWorkFailure(code: code, reason: reason(code) ?? message)
    }
}

/// The Invite People sheet's words (design chat-multiplayer.md 2), for the App's view.
public extension AgentShareInviteSheetModel {
    var title: String {
        String(format: String(localized: "agentShare.sheet.title", defaultValue: "Invite People to “%@”", table: "AgentShare", bundle: .module), chat)
    }

    var intro: String {
        String(localized: "agentShare.sheet.body", defaultValue: "People you invite sign in with their cmux account and see this chat as you do, including command output and the agent’s reasoning.", table: "AgentShare", bundle: .module)
    }

    var accountPlaceholder: String {
        String(localized: "agentShare.sheet.account", defaultValue: "Email or @handle", table: "AgentShare", bundle: .module)
    }

    var inviteTitle: String { AgentShareStrings.inviteConsentAllow }

    /// The role's name in the picker and on a row.
    func roleTitle(_ role: String) -> String {
        if role == "view" {
            return String(localized: "agentShare.sheet.canView", defaultValue: "Can view", table: "AgentShare", bundle: .module)
        }
        return String(localized: "agentShare.sheet.canTalk", defaultValue: "Can talk", table: "AgentShare", bundle: .module)
    }

    /// What the chosen role lets them do, under the field.
    var roleDetail: String { AgentShareStrings.inviteRoleLine(role) }

    /// A row's second line: the role, and whether a device of theirs is in the chat now.
    func rowDetail(_ row: Row) -> String {
        guard row.joined else { return roleTitle(row.role) }
        return String(format: String(localized: "agentShare.sheet.joined", defaultValue: "%@ · In the chat now", table: "AgentShare", bundle: .module), roleTitle(row.role))
    }

    var removeTitle: String {
        String(localized: "agentShare.sheet.remove", defaultValue: "Remove", table: "AgentShare", bundle: .module)
    }

    var emptyText: String {
        String(localized: "agentShare.sheet.empty", defaultValue: "No one is invited yet.", table: "AgentShare", bundle: .module)
    }

    /// Remove (the account) versus removing one device from the chat (a kick).
    var removeNote: String {
        String(localized: "agentShare.sheet.removeNote", defaultValue: "Remove ends their access on every device. Removing just one of their devices from the chat doesn’t keep their account out.", table: "AgentShare", bundle: .module)
    }

    var closeTitle: String {
        String(localized: "agentShare.sheet.close", defaultValue: "Close", table: "AgentShare", bundle: .module)
    }

    var copyLinkTitle: String {
        String(localized: "agentShare.sheet.copyLink", defaultValue: "Copy Invite Link", table: "AgentShare", bundle: .module)
    }

    /// Copy Invite Link's title for a moment after a press.
    var copiedTitle: String {
        String(localized: "agentShare.sheet.copied", defaultValue: "Copied", table: "AgentShare", bundle: .module)
    }
}
