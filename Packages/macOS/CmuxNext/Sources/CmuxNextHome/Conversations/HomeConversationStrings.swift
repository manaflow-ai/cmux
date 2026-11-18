public import AppKit
public import CmuxHomeCore
import CmuxNextHomeModel
import Foundation

/// The strings of the Home page's conversation list and its sheets
/// (Localizable.xcstrings, keys `home.list.*`, `home.compose.*`,
/// `home.invite.*`, `home.chief.new.*`).
enum HomeConversationStrings {
    /// The sidebar search section of teammates the user has no DM with yet.
    static var teammatesSection: String { String(localized: "home.list.teammates", defaultValue: "Teammates", bundle: .l10n) }
    static var newMessage: String { String(localized: "home.list.newMessage", defaultValue: "New Message…", bundle: .l10n) }
    /// The list's on-filter chip (Unread ×): what a click does.
    static var filterChipHelp: String {
        String(localized: "home.list.filterChipHelp", defaultValue: "Turns the Unread filter off and shows every chat", bundle: .l10n)
    }
    static var newChief: String { String(localized: "home.list.newChief", defaultValue: "New Chief…", bundle: .l10n) }
    static var invite: String { String(localized: "home.list.invite", defaultValue: "Invite to cmux-next…", bundle: .l10n) }
    /// Group info's Invite by Email… after a `not_reachable` refusal.
    static var inviteByEmail: String { String(localized: "home.groupInfo.inviteByEmail", defaultValue: "Invite by Email…", bundle: .l10n) }
    static var empty: String {
        String(localized: "home.list.empty", defaultValue: "No conversations yet. Start one with New Message.", bundle: .l10n)
    }

    static func header(_ kind: HomeConversationSectionKind) -> String {
        switch kind {
        case .chiefs: String(localized: "home.list.section.chiefs", defaultValue: "Chiefs", bundle: .l10n)
        case .pinned: String(localized: "home.list.section.pinned", defaultValue: "Pinned", bundle: .l10n)
        case .messages: String(localized: "home.list.section.messages", defaultValue: "Direct Messages and Groups", bundle: .l10n)
        case .invited: String(localized: "home.list.section.invited", defaultValue: "Invited", bundle: .l10n)
        }
    }

    /// The bundle of this module's catalog, so a test can read one language's table (`fr.lproj`).
    static var bundle: Bundle { .l10n }

    /// "3 unread" in the row's VoiceOver label; a plural string, so each locale picks its form for
    /// `count`. `bundle` and `locale` default to this module's catalog in the user's language; a
    /// test passes one language's table and its locale.
    static func unread(_ count: Int, bundle: Bundle = .l10n, locale: Locale = .current) -> String {
        String(localized: "home.list.unread", defaultValue: "\(count) unread", bundle: bundle, locale: locale)
    }

    static var mentioned: String { String(localized: "home.list.mentioned", defaultValue: "Mentions you", bundle: .l10n) }
    static var pinnedLabel: String { String(localized: "home.list.pinnedLabel", defaultValue: "Pinned", bundle: .l10n) }
    static var invitedLabel: String { String(localized: "home.list.invitedLabel", defaultValue: "Waiting for them to join", bundle: .l10n) }
    /// The quiet line under the list for the Cloud rows' state (`home-inbox` `cloud`): only `unavailable`
    /// has one (hq-6d 2026-10-15: signed out shows nothing; the account menu already says so).
    static func cloudNote(_ state: String?) -> String? {
        guard state == "unavailable" else { return nil }
        return String(localized: "home.list.cloudUnavailable", defaultValue: "Cloud conversations are not available right now.", bundle: .l10n)
    }
    static var untitled: String { String(localized: "home.list.untitled", defaultValue: "Conversation", bundle: .l10n) }

    // MARK: Group chats with Chiefs (chief-group-chats-DESIGN.md)

    /// Group info's Chiefs Reply row label.
    static var infoChiefReplies: String { String(localized: "home.groupInfo.chiefReplies", defaultValue: "Chiefs Reply", bundle: .l10n) }

    /// One choice of the Chiefs Reply row.
    static func chiefReplies(_ policy: ChiefReplyPolicy) -> String {
        switch policy {
        case .auto: String(localized: "home.groupInfo.chiefReplies.auto", defaultValue: "Automatically", bundle: .l10n)
        case .mentions: String(localized: "home.groupInfo.chiefReplies.mentions", defaultValue: "Only When @Mentioned", bundle: .l10n)
        case .all: String(localized: "home.groupInfo.chiefReplies.all", defaultValue: "To Every Message", bundle: .l10n)
        }
    }

    /// The line under the Chiefs Reply row that says what the choice does.
    static func chiefRepliesDetail(_ policy: ChiefReplyPolicy) -> String {
        switch policy {
        case .auto:
            String(localized: "home.groupInfo.chiefReplies.auto.detail",
                   defaultValue: "A Chief answers when you @mention it or reply to it. With only you and one Chief, it answers every message.",
                   bundle: .l10n)
        case .mentions:
            String(localized: "home.groupInfo.chiefReplies.mentions.detail",
                   defaultValue: "A Chief answers only when you @mention it or reply to it.", bundle: .l10n)
        case .all:
            String(localized: "home.groupInfo.chiefReplies.all.detail",
                   defaultValue: "Every Chief answers every message that a person sends.", bundle: .l10n)
        }
    }

    // MARK: Chiefs (HomeChiefRoster)

    /// The tag after a channel's name in the Home list (plans/cmux-next/chief-channels-DESIGN.md).
    static var channelTag: String { String(localized: "home.list.channel", defaultValue: "Channel", bundle: .l10n) }

    // MARK: Message requests (home-messaging-invites DESIGN 2.3, 2.5)

    /// The sender's row while the other person has not joined.
    static func waitingFor(_ name: String) -> String {
        String(format: String(localized: "home.invite.waitingFor", defaultValue: "Waiting for %@ to accept", bundle: .l10n), name)
    }
    /// The sidebar's button to the requests.
    static func requestsBar(_ count: Int) -> String {
        String(format: String(localized: "home.requests.bar", defaultValue: "Message Requests (%lld)", bundle: .l10n), count)
    }
    static var requestsTitle: String { String(localized: "home.requests.title", defaultValue: "Message Requests", bundle: .l10n) }
    static var requestsBody: String {
        String(localized: "home.requests.body",
               defaultValue: "People you have not talked to yet. They do not get notified, and they do not know if you read their message.",
               bundle: .l10n)
    }
    static var requestsNone: String { String(localized: "home.requests.none", defaultValue: "No message requests.", bundle: .l10n) }
    static var requestsDone: String { String(localized: "home.requests.done", defaultValue: "Done", bundle: .l10n) }
    static var requestAccept: String { String(localized: "home.requests.accept", defaultValue: "Accept", bundle: .l10n) }
    static var requestDecline: String { String(localized: "home.requests.decline", defaultValue: "Decline", bundle: .l10n) }
    static var requestBlock: String { String(localized: "home.requests.block", defaultValue: "Block", bundle: .l10n) }
    static var requestTrusted: String { String(localized: "home.requests.trusted", defaultValue: "Same company", bundle: .l10n) }
    /// A group request's line: "Invited you to Lunch".
    static func requestGroup(_ title: String) -> String {
        String(format: String(localized: "home.requests.group", defaultValue: "Invited you to %@", bundle: .l10n), title)
    }
    static var requestGroupUntitled: String {
        String(localized: "home.requests.groupUntitled", defaultValue: "Invited you to a group", bundle: .l10n)
    }
    static var requestFailed: String { String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .l10n) }

    // MARK: New Message

    /// The draft row's title and the page's name (Messages' "New Message").
    static var composeTitle: String { String(localized: "home.compose.title", defaultValue: "New Message", bundle: .l10n) }
    /// The x on the list's New Message row and the action that discards the draft.
    static var closeNewMessage: String { String(localized: "home.compose.close", defaultValue: "Close New Message", bundle: .l10n) }
    /// The To: field's VoiceOver label.
    static var composeSearch: String {
        String(localized: "home.compose.search", defaultValue: "Name or email address", bundle: .l10n)
    }
    static var cancel: String { String(localized: "home.compose.cancel", defaultValue: "Cancel", bundle: .l10n) }
    /// The To: field's value for VoiceOver: the chosen names.
    static func composeTo(_ names: String) -> String {
        String(format: String(localized: "home.compose.to", defaultValue: "To: %@", bundle: .l10n), names)
    }
    /// The + button's suggestions when the user has nobody to pick yet.
    static var composeNoContacts: String {
        String(localized: "home.compose.noContacts", defaultValue: "No teammates yet. Invite someone by email.", bundle: .l10n)
    }
    static var sourceTeam: String { String(localized: "home.compose.source.team", defaultValue: "Team", bundle: .l10n) }
    static var sourceConnection: String { String(localized: "home.compose.source.connection", defaultValue: "Contact", bundle: .l10n) }
    static var sourceAgent: String { String(localized: "home.compose.source.agent", defaultValue: "Chief", bundle: .l10n) }
    /// The To: list's section of the user's Chiefs (the Home list's "Chiefs" header).
    static var chiefsSection: String { header(.chiefs) }
    /// The To: list's section of the user's team members.
    static var teamSection: String { String(localized: "home.compose.section.team", defaultValue: "Team", bundle: .l10n) }
    /// The To: list's line for a Chief that reads like another one: when it was last active ("Active 2 hours ago").
    static func activeAgo(_ relative: String) -> String {
        String(format: String(localized: "home.compose.activeAgo", defaultValue: "Active %@", bundle: .l10n), relative)
    }
    /// The To: list's line for a Chief that reads like another one and has no messages yet.
    static var noMessagesYet: String { String(localized: "home.compose.noMessagesYet", defaultValue: "No messages yet", bundle: .l10n) }
    /// The label in front of the recipient tokens.
    static var toLabel: String { String(localized: "home.compose.toLabel", defaultValue: "To:", bundle: .l10n) }
    /// The + button at the end of the To: field (all people to pick from).
    static var addRecipient: String { String(localized: "home.compose.addRecipient", defaultValue: "Add Recipient", bundle: .l10n) }
    static var addressEmail: String { String(localized: "home.compose.address.email", defaultValue: "Email", bundle: .l10n) }
    static var addressPhone: String { String(localized: "home.compose.address.phone", defaultValue: "Phone", bundle: .l10n) }
    /// A token's remove button (VoiceOver).
    static func removeRecipient(_ name: String) -> String {
        String(format: String(localized: "home.compose.removeRecipient", defaultValue: "Remove %@", bundle: .l10n), name)
    }
    /// A red token: the typed text names nobody.
    static func unknownRecipient(_ text: String) -> String {
        String(format: String(localized: "home.compose.unknownRecipient",
                              defaultValue: "No one named “%@”. Type their email address to invite them.", bundle: .l10n), text)
    }
    /// Return in the message box before anyone is in To:.
    static var needsRecipient: String {
        String(localized: "home.compose.needsRecipient", defaultValue: "Add someone in To: first.", bundle: .l10n)
    }

    // MARK: Invite

    static var inviteTitle: String { String(localized: "home.invite.title", defaultValue: "Invite to cmux-next", bundle: .l10n) }
    static var inviteBody: String {
        String(localized: "home.invite.body",
               defaultValue: "They get an email with a link to join. You can message them here as soon as they accept.",
               bundle: .l10n)
    }
    static var inviteEmail: String { String(localized: "home.invite.email", defaultValue: "Email address", bundle: .l10n) }
    static var inviteSend: String { String(localized: "home.invite.send", defaultValue: "Send Invite", bundle: .l10n) }
    static var invitePending: String { String(localized: "home.invite.pending", defaultValue: "Pending invites", bundle: .l10n) }
    static var inviteNonePending: String { String(localized: "home.invite.nonePending", defaultValue: "No pending invites.", bundle: .l10n) }

    // MARK: Invite to Team

    static func teamInviteTitle(_ team: String) -> String {
        String(format: String(localized: "home.teamInvite.title", defaultValue: "Invite to %@", bundle: .l10n), team)
    }
    static func teamInviteBody(_ team: String) -> String {
        String(format: String(localized: "home.teamInvite.body", defaultValue: "They get an email with a link to join %@.", bundle: .l10n), team)
    }
    static func inviteAddressToTeam(_ email: String, team: String) -> String {
        String(format: String(localized: "home.teamInvite.row", defaultValue: "Invite %1$@ to %2$@", bundle: .l10n), email, team)
    }
    static var teamInviteChecking: String {
        String(localized: "home.teamInvite.checking", defaultValue: "Checking the team’s plan…", bundle: .l10n)
    }
    static var teamInviteRequested: String {
        String(localized: "home.teamInvite.requested",
               defaultValue: "An agent asked to send this invite. Check the address before you send it.", bundle: .l10n)
    }

    /// The confirmation line: what a join costs the team.
    static func seatImpact(_ impact: HomeTeamSeatImpact) -> String {
        switch impact {
        case .paidSeat:
            String(localized: "home.teamInvite.paidSeat", defaultValue: "When they join, the Team plan bills one more seat, prorated.",
                   bundle: .l10n)
        case .capped(let members, let limit):
            String(format: String(localized: "home.teamInvite.capped", defaultValue: "The plan has room for %2$d members; %1$d are in the team now.",
                                  bundle: .l10n), members, limit)
        case .free:
            String(localized: "home.teamInvite.free", defaultValue: "No charge: this team has no paid plan.", bundle: .l10n)
        case .unknown:
            String(localized: "home.teamInvite.unknown", defaultValue: "The team’s plan couldn’t be read. Joining may add a paid seat.",
                   bundle: .l10n)
        case .notAllowed:
            HomeModelStrings.teamInviteNotAllowed
        }
    }

    // MARK: New Chief

    static var chiefTitle: String { String(localized: "home.chief.new.title", defaultValue: "New Chief", bundle: .l10n) }
    static var chiefBody: String {
        String(localized: "home.chief.new.body",
               defaultValue: "A Chief is an agent with its own conversation and memory. Chiefs are optional.", bundle: .l10n)
    }
    static var chiefName: String { String(localized: "home.chief.new.name", defaultValue: "Name", bundle: .l10n) }
    static var chiefCreate: String { String(localized: "home.chief.new.create", defaultValue: "Create", bundle: .l10n) }
    static var chiefBackend: String { String(localized: "home.chief.new.backend", defaultValue: "Backend", bundle: .l10n) }

    // MARK: Sidebar previews

    static var yesterday: String { String(localized: "home.sidebar.yesterday", defaultValue: "Yesterday", bundle: .l10n) }
    static var you: String { String(localized: "home.sidebar.you", defaultValue: "You", bundle: .l10n) }

    /// "Lucas loved “Good luck!”", in the tapback's own words.
    static func reaction(_ kind: Reaction.Kind, by who: String, to text: String) -> String {
        switch kind {
        case .tapback(.love):
            String(format: String(localized: "home.sidebar.reaction.love", defaultValue: "%1$@ loved “%2$@”", bundle: .l10n), who, text)
        case .tapback(.like):
            String(format: String(localized: "home.sidebar.reaction.like", defaultValue: "%1$@ liked “%2$@”", bundle: .l10n), who, text)
        case .tapback(.dislike):
            String(format: String(localized: "home.sidebar.reaction.dislike", defaultValue: "%1$@ disliked “%2$@”", bundle: .l10n), who, text)
        case .tapback(.laugh):
            String(format: String(localized: "home.sidebar.reaction.laugh", defaultValue: "%1$@ laughed at “%2$@”", bundle: .l10n), who, text)
        case .tapback(.emphasize):
            String(format: String(localized: "home.sidebar.reaction.emphasize", defaultValue: "%1$@ emphasized “%2$@”", bundle: .l10n), who, text)
        case .tapback(.question):
            String(format: String(localized: "home.sidebar.reaction.question", defaultValue: "%1$@ questioned “%2$@”", bundle: .l10n), who, text)
        case .emoji(let emoji):
            String(format: String(localized: "home.sidebar.reaction.emoji", defaultValue: "%1$@ reacted %2$@ to “%3$@”", bundle: .l10n),
                   who, emoji, text)
        }
    }


    // MARK: Group info

    static var infoGroupTitle: String { String(localized: "home.info.title.group", defaultValue: "Group Info", bundle: .l10n) }
    static var infoDirectTitle: String { String(localized: "home.info.title.direct", defaultValue: "Info", bundle: .l10n) }
    static var infoName: String { String(localized: "home.info.name", defaultValue: "Group name", bundle: .l10n) }
    static var infoRename: String { String(localized: "home.info.rename", defaultValue: "Rename", bundle: .l10n) }
    static var infoYou: String { String(localized: "home.info.you", defaultValue: "You", bundle: .l10n) }
    static var infoInvited: String { String(localized: "home.info.invited", defaultValue: "Invited", bundle: .l10n) }
    static var infoAgent: String { String(localized: "home.info.agent", defaultValue: "Agent", bundle: .l10n) }
    static var infoRemove: String { String(localized: "home.info.remove", defaultValue: "Remove", bundle: .l10n) }
    static var infoAddPeople: String { String(localized: "home.info.addPeople", defaultValue: "Add People…", bundle: .l10n) }
    static var infoAdd: String { String(localized: "home.info.add", defaultValue: "Add", bundle: .l10n) }
    static var infoAddSearch: String { String(localized: "home.info.addSearch", defaultValue: "Search people", bundle: .l10n) }
    static var infoNoOneToAdd: String {
        String(localized: "home.info.noOneToAdd", defaultValue: "Everyone you can message is already here.", bundle: .l10n)
    }
    static var infoHideAlerts: String { String(localized: "home.info.hideAlerts", defaultValue: "Hide Alerts", bundle: .l10n) }
    static var infoLeave: String { String(localized: "home.info.leave", defaultValue: "Leave Group…", bundle: .l10n) }
    static var infoDone: String { String(localized: "home.info.done", defaultValue: "Done", bundle: .l10n) }
}
