public import AppKit
public import CmuxHomeCore
import CmuxNextHomeModel
import Foundation

/// The strings of the Home page's conversation list and its sheets
/// (Localizable.xcstrings, keys `home.list.*`, `home.compose.*`,
/// `home.invite.*`, `home.chief.new.*`).
enum HomeConversationStrings {
    /// The sidebar search section of teammates the user has no DM with yet.
    static var teammatesSection: String { String(localized: "home.list.teammates", defaultValue: "Teammates", bundle: .module) }
    /// The sidebar search section of messages whose text matches (Messages' search).
    static var messagesSection: String { String(localized: "home.list.searchMessages", defaultValue: "Messages", bundle: .module) }
    static var newMessage: String { String(localized: "home.list.newMessage", defaultValue: "New Message…", bundle: .module) }
    /// The list's on-filter chip (Unread ×): what a click does.
    static var filterChipHelp: String {
        String(localized: "home.list.filterChipHelp", defaultValue: "Turns the Unread filter off and shows every chat", bundle: .module)
    }
    static var newChief: String { String(localized: "home.list.newChief", defaultValue: "New Chief…", bundle: .module) }
    static var invite: String { String(localized: "home.list.invite", defaultValue: "Invite to cmux-next…", bundle: .module) }
    /// Group info's Invite by Email… after a `not_reachable` refusal.
    static var inviteByEmail: String { String(localized: "home.groupInfo.inviteByEmail", defaultValue: "Invite by Email…", bundle: .module) }
    static var empty: String {
        String(localized: "home.list.empty", defaultValue: "No conversations yet. Start one with New Message.", bundle: .module)
    }

    static func header(_ kind: HomeConversationSectionKind) -> String {
        switch kind {
        case .chiefs: String(localized: "home.list.section.chiefs", defaultValue: "Chiefs", bundle: .module)
        case .pinned: String(localized: "home.list.section.pinned", defaultValue: "Pinned", bundle: .module)
        case .messages: String(localized: "home.list.section.messages", defaultValue: "Direct Messages and Groups", bundle: .module)
        case .invited: String(localized: "home.list.section.invited", defaultValue: "Invited", bundle: .module)
        }
    }

    /// The bundle of this module's catalog, so a test can read one language's table (`fr.lproj`).
    static var bundle: Bundle { .module }

    /// "3 unread" in the row's VoiceOver label; a plural string, so each locale picks its form for
    /// `count`. `bundle` and `locale` default to this module's catalog in the user's language; a
    /// test passes one language's table and its locale.
    static func unread(_ count: Int, bundle: Bundle = .module, locale: Locale = .current) -> String {
        String(localized: "home.list.unread", defaultValue: "\(count) unread", bundle: bundle, locale: locale)
    }

    static var mentioned: String { String(localized: "home.list.mentioned", defaultValue: "Mentions you", bundle: .module) }
    static var pinnedLabel: String { String(localized: "home.list.pinnedLabel", defaultValue: "Pinned", bundle: .module) }
    static var invitedLabel: String { String(localized: "home.list.invitedLabel", defaultValue: "Waiting for them to join", bundle: .module) }
    /// The quiet line under the list for the Cloud rows' state (`home-inbox` `cloud`): only `unavailable`
    /// has one (hq-6d 2026-10-15: signed out shows nothing; the account menu already says so).
    static func cloudNote(_ state: String?) -> String? {
        guard state == "unavailable" else { return nil }
        return String(localized: "home.list.cloudUnavailable", defaultValue: "Cloud conversations are not available right now.", bundle: .module)
    }
    static var untitled: String { String(localized: "home.list.untitled", defaultValue: "Conversation", bundle: .module) }

    // MARK: Group chats with Chiefs (chief-group-chats-DESIGN.md)

    /// Group info's Chiefs Reply row label.
    static var infoChiefReplies: String { String(localized: "home.groupInfo.chiefReplies", defaultValue: "Chiefs Reply", bundle: .module) }

    /// One choice of the Chiefs Reply row.
    static func chiefReplies(_ policy: ChiefReplyPolicy) -> String {
        switch policy {
        case .auto: String(localized: "home.groupInfo.chiefReplies.auto", defaultValue: "Automatically", bundle: .module)
        case .mentions: String(localized: "home.groupInfo.chiefReplies.mentions", defaultValue: "Only When @Mentioned", bundle: .module)
        case .all: String(localized: "home.groupInfo.chiefReplies.all", defaultValue: "To Every Message", bundle: .module)
        }
    }

    /// The line under the Chiefs Reply row that says what the choice does.
    static func chiefRepliesDetail(_ policy: ChiefReplyPolicy) -> String {
        switch policy {
        case .auto:
            String(localized: "home.groupInfo.chiefReplies.auto.detail",
                   defaultValue: "A Chief answers when you @mention it or reply to it. With only you and one Chief, it answers every message.",
                   bundle: .module)
        case .mentions:
            String(localized: "home.groupInfo.chiefReplies.mentions.detail",
                   defaultValue: "A Chief answers only when you @mention it or reply to it.", bundle: .module)
        case .all:
            String(localized: "home.groupInfo.chiefReplies.all.detail",
                   defaultValue: "Every Chief answers every message that a person sends.", bundle: .module)
        }
    }

    // MARK: Chiefs (HomeChiefRoster)

    /// The tag after a channel's name in the Home list (plans/cmux-next/chief-channels-DESIGN.md).
    static var channelTag: String { String(localized: "home.list.channel", defaultValue: "Channel", bundle: .module) }

    // MARK: Message requests (home-messaging-invites DESIGN 2.3, 2.5)

    /// The sender's row while the other person has not joined.
    static func waitingFor(_ name: String) -> String {
        String(format: String(localized: "home.invite.waitingFor", defaultValue: "Waiting for %@ to accept", bundle: .module), name)
    }
    /// The sidebar's button to the requests.
    static func requestsBar(_ count: Int) -> String {
        String(format: String(localized: "home.requests.bar", defaultValue: "Message Requests (%lld)", bundle: .module), count)
    }
    static var requestsTitle: String { String(localized: "home.requests.title", defaultValue: "Message Requests", bundle: .module) }
    static var requestsBody: String {
        String(localized: "home.requests.body",
               defaultValue: "People you have not talked to yet. They do not get notified, and they do not know if you read their message.",
               bundle: .module)
    }
    static var requestsNone: String { String(localized: "home.requests.none", defaultValue: "No message requests.", bundle: .module) }
    static var requestsDone: String { String(localized: "home.requests.done", defaultValue: "Done", bundle: .module) }
    static var requestAccept: String { String(localized: "home.requests.accept", defaultValue: "Accept", bundle: .module) }
    static var requestDecline: String { String(localized: "home.requests.decline", defaultValue: "Decline", bundle: .module) }
    static var requestBlock: String { String(localized: "home.requests.block", defaultValue: "Block", bundle: .module) }
    static var requestTrusted: String { String(localized: "home.requests.trusted", defaultValue: "Same company", bundle: .module) }
    /// A group request's line: "Invited you to Lunch".
    static func requestGroup(_ title: String) -> String {
        String(format: String(localized: "home.requests.group", defaultValue: "Invited you to %@", bundle: .module), title)
    }
    static var requestGroupUntitled: String {
        String(localized: "home.requests.groupUntitled", defaultValue: "Invited you to a group", bundle: .module)
    }
    static var requestFailed: String { String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .module) }

    // MARK: New Message

    /// The draft row's title and the page's name (Messages' "New Message").
    static var composeTitle: String { String(localized: "home.compose.title", defaultValue: "New Message", bundle: .module) }
    /// The x on the list's New Message row and the action that discards the draft.
    static var closeNewMessage: String { String(localized: "home.compose.close", defaultValue: "Close New Message", bundle: .module) }
    /// The To: field's VoiceOver label.
    static var composeSearch: String {
        String(localized: "home.compose.search", defaultValue: "Name or email address", bundle: .module)
    }
    static var cancel: String { String(localized: "home.compose.cancel", defaultValue: "Cancel", bundle: .module) }
    /// The To: field's value for VoiceOver: the chosen names.
    static func composeTo(_ names: String) -> String {
        String(format: String(localized: "home.compose.to", defaultValue: "To: %@", bundle: .module), names)
    }
    /// The + button's suggestions when the user has nobody to pick yet.
    static var composeNoContacts: String {
        String(localized: "home.compose.noContacts", defaultValue: "No teammates yet. Invite someone by email.", bundle: .module)
    }
    static var sourceTeam: String { String(localized: "home.compose.source.team", defaultValue: "Team", bundle: .module) }
    static var sourceConnection: String { String(localized: "home.compose.source.connection", defaultValue: "Contact", bundle: .module) }
    static var sourceAgent: String { String(localized: "home.compose.source.agent", defaultValue: "Chief", bundle: .module) }
    /// The To: list's section of the user's Chiefs (the Home list's "Chiefs" header).
    static var chiefsSection: String { header(.chiefs) }
    /// The To: list's section of the user's team members.
    static var teamSection: String { String(localized: "home.compose.section.team", defaultValue: "Team", bundle: .module) }
    /// The To: list's line for a Chief that reads like another one: when it was last active ("Active 2 hours ago").
    static func activeAgo(_ relative: String) -> String {
        String(format: String(localized: "home.compose.activeAgo", defaultValue: "Active %@", bundle: .module), relative)
    }
    /// The To: list's line for a Chief that reads like another one and has no messages yet.
    static var noMessagesYet: String { String(localized: "home.compose.noMessagesYet", defaultValue: "No messages yet", bundle: .module) }
    /// The label in front of the recipient tokens.
    static var toLabel: String { String(localized: "home.compose.toLabel", defaultValue: "To:", bundle: .module) }
    /// The + button at the end of the To: field (all people to pick from).
    static var addRecipient: String { String(localized: "home.compose.addRecipient", defaultValue: "Add Recipient", bundle: .module) }
    static var addressEmail: String { String(localized: "home.compose.address.email", defaultValue: "Email", bundle: .module) }
    static var addressPhone: String { String(localized: "home.compose.address.phone", defaultValue: "Phone", bundle: .module) }
    /// A token's remove button (VoiceOver).
    static func removeRecipient(_ name: String) -> String {
        String(format: String(localized: "home.compose.removeRecipient", defaultValue: "Remove %@", bundle: .module), name)
    }
    /// A red token: the typed text names nobody.
    static func unknownRecipient(_ text: String) -> String {
        String(format: String(localized: "home.compose.unknownRecipient",
                              defaultValue: "No one named “%@”. Type their email address to invite them.", bundle: .module), text)
    }
    /// Return in the message box before anyone is in To:.
    static var needsRecipient: String {
        String(localized: "home.compose.needsRecipient", defaultValue: "Add someone in To: first.", bundle: .module)
    }

    // MARK: Invite

    static var inviteTitle: String { String(localized: "home.invite.title", defaultValue: "Invite to cmux-next", bundle: .module) }
    static var inviteBody: String {
        String(localized: "home.invite.body",
               defaultValue: "They get an email with a link to join. You can message them here as soon as they accept.",
               bundle: .module)
    }
    static var inviteEmail: String { String(localized: "home.invite.email", defaultValue: "Email address", bundle: .module) }
    static var inviteSend: String { String(localized: "home.invite.send", defaultValue: "Send Invite", bundle: .module) }
    static var invitePending: String { String(localized: "home.invite.pending", defaultValue: "Pending invites", bundle: .module) }
    static var inviteNonePending: String { String(localized: "home.invite.nonePending", defaultValue: "No pending invites.", bundle: .module) }

    // MARK: Invite to Team

    static func teamInviteTitle(_ team: String) -> String {
        String(format: String(localized: "home.teamInvite.title", defaultValue: "Invite to %@", bundle: .module), team)
    }
    static func teamInviteBody(_ team: String) -> String {
        String(format: String(localized: "home.teamInvite.body", defaultValue: "They get an email with a link to join %@.", bundle: .module), team)
    }
    static func inviteAddressToTeam(_ email: String, team: String) -> String {
        String(format: String(localized: "home.teamInvite.row", defaultValue: "Invite %1$@ to %2$@", bundle: .module), email, team)
    }
    static var teamInviteChecking: String {
        String(localized: "home.teamInvite.checking", defaultValue: "Checking the team’s plan…", bundle: .module)
    }
    static var teamInviteRequested: String {
        String(localized: "home.teamInvite.requested",
               defaultValue: "An agent asked to send this invite. Check the address before you send it.", bundle: .module)
    }

    /// The confirmation line: what a join costs the team.
    static func seatImpact(_ impact: HomeTeamSeatImpact) -> String {
        switch impact {
        case .paidSeat:
            String(localized: "home.teamInvite.paidSeat", defaultValue: "When they join, the Team plan bills one more seat, prorated.",
                   bundle: .module)
        case .capped(let members, let limit):
            String(format: String(localized: "home.teamInvite.capped", defaultValue: "The plan has room for %2$d members; %1$d are in the team now.",
                                  bundle: .module), members, limit)
        case .free:
            String(localized: "home.teamInvite.free", defaultValue: "No charge: this team has no paid plan.", bundle: .module)
        case .unknown:
            String(localized: "home.teamInvite.unknown", defaultValue: "The team’s plan couldn’t be read. Joining may add a paid seat.",
                   bundle: .module)
        case .notAllowed:
            HomeModelStrings.teamInviteNotAllowed
        }
    }

    // MARK: New Chief

    static var chiefTitle: String { String(localized: "home.chief.new.title", defaultValue: "New Chief", bundle: .module) }
    static var chiefBody: String {
        String(localized: "home.chief.new.body",
               defaultValue: "A Chief is an agent with its own conversation and memory. Chiefs are optional.", bundle: .module)
    }
    static var chiefName: String { String(localized: "home.chief.new.name", defaultValue: "Name", bundle: .module) }
    static var chiefCreate: String { String(localized: "home.chief.new.create", defaultValue: "Create", bundle: .module) }
    static var chiefBackend: String { String(localized: "home.chief.new.backend", defaultValue: "Backend", bundle: .module) }

    // MARK: Sidebar previews

    static var yesterday: String { String(localized: "home.sidebar.yesterday", defaultValue: "Yesterday", bundle: .module) }
    static var you: String { String(localized: "home.sidebar.you", defaultValue: "You", bundle: .module) }

    /// "Lucas loved “Good luck!”", in the tapback's own words.
    static func reaction(_ kind: Reaction.Kind, by who: String, to text: String) -> String {
        switch kind {
        case .tapback(.love):
            String(format: String(localized: "home.sidebar.reaction.love", defaultValue: "%1$@ loved “%2$@”", bundle: .module), who, text)
        case .tapback(.like):
            String(format: String(localized: "home.sidebar.reaction.like", defaultValue: "%1$@ liked “%2$@”", bundle: .module), who, text)
        case .tapback(.dislike):
            String(format: String(localized: "home.sidebar.reaction.dislike", defaultValue: "%1$@ disliked “%2$@”", bundle: .module), who, text)
        case .tapback(.laugh):
            String(format: String(localized: "home.sidebar.reaction.laugh", defaultValue: "%1$@ laughed at “%2$@”", bundle: .module), who, text)
        case .tapback(.emphasize):
            String(format: String(localized: "home.sidebar.reaction.emphasize", defaultValue: "%1$@ emphasized “%2$@”", bundle: .module), who, text)
        case .tapback(.question):
            String(format: String(localized: "home.sidebar.reaction.question", defaultValue: "%1$@ questioned “%2$@”", bundle: .module), who, text)
        case .emoji(let emoji):
            String(format: String(localized: "home.sidebar.reaction.emoji", defaultValue: "%1$@ reacted %2$@ to “%3$@”", bundle: .module),
                   who, emoji, text)
        }
    }


    // MARK: Group info

    static var infoGroupTitle: String { String(localized: "home.info.title.group", defaultValue: "Group Info", bundle: .module) }
    static var infoDirectTitle: String { String(localized: "home.info.title.direct", defaultValue: "Info", bundle: .module) }
    static var infoName: String { String(localized: "home.info.name", defaultValue: "Group name", bundle: .module) }
    static var infoRename: String { String(localized: "home.info.rename", defaultValue: "Rename", bundle: .module) }
    static var infoYou: String { String(localized: "home.info.you", defaultValue: "You", bundle: .module) }
    static var infoInvited: String { String(localized: "home.info.invited", defaultValue: "Invited", bundle: .module) }
    static var infoAgent: String { String(localized: "home.info.agent", defaultValue: "Agent", bundle: .module) }
    static var infoRemove: String { String(localized: "home.info.remove", defaultValue: "Remove", bundle: .module) }
    static var infoAddPeople: String { String(localized: "home.info.addPeople", defaultValue: "Add People…", bundle: .module) }
    static var infoAdd: String { String(localized: "home.info.add", defaultValue: "Add", bundle: .module) }
    static var infoAddSearch: String { String(localized: "home.info.addSearch", defaultValue: "Search people", bundle: .module) }
    static var infoNoOneToAdd: String {
        String(localized: "home.info.noOneToAdd", defaultValue: "Everyone you can message is already here.", bundle: .module)
    }
    static var infoHideAlerts: String { String(localized: "home.info.hideAlerts", defaultValue: "Hide Alerts", bundle: .module) }
    static var infoLeave: String { String(localized: "home.info.leave", defaultValue: "Leave Group…", bundle: .module) }
    static var infoDone: String { String(localized: "home.info.done", defaultValue: "Done", bundle: .module) }
}
