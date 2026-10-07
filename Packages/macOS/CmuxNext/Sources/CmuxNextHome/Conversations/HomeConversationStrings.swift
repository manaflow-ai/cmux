public import AppKit
public import CmuxHomeCore
import Foundation

/// The strings of the Home page's conversation list and its sheets
/// (Localizable.xcstrings, keys `home.list.*`, `home.compose.*`,
/// `home.invite.*`, `home.chief.new.*`).
enum HomeConversationStrings {
    static var newMessage: String { String(localized: "home.list.newMessage", defaultValue: "New Message…", bundle: .module) }
    static var newChief: String { String(localized: "home.list.newChief", defaultValue: "New Chief…", bundle: .module) }
    static var invite: String { String(localized: "home.list.invite", defaultValue: "Invite to cmux-next…", bundle: .module) }
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

    static func unread(_ count: Int) -> String {
        String(format: String(localized: "home.list.unread", defaultValue: "%lld unread", bundle: .module), count)
    }

    static var mentioned: String { String(localized: "home.list.mentioned", defaultValue: "Mentions you", bundle: .module) }
    static var pinnedLabel: String { String(localized: "home.list.pinnedLabel", defaultValue: "Pinned", bundle: .module) }
    static var invitedLabel: String { String(localized: "home.list.invitedLabel", defaultValue: "Waiting for them to join", bundle: .module) }
    static var untitled: String { String(localized: "home.list.untitled", defaultValue: "Conversation", bundle: .module) }

    // MARK: New Message

    static var composeTitle: String { String(localized: "home.compose.title", defaultValue: "New Message", bundle: .module) }
    static var composeSearch: String {
        String(localized: "home.compose.search", defaultValue: "Name or email address", bundle: .module)
    }
    static var composeGroupName: String {
        String(localized: "home.compose.groupName", defaultValue: "Group name (optional)", bundle: .module)
    }
    static var composeStart: String { String(localized: "home.compose.start", defaultValue: "Start", bundle: .module) }
    static var cancel: String { String(localized: "home.compose.cancel", defaultValue: "Cancel", bundle: .module) }
    static func composeAddAddress(_ address: String) -> String {
        String(format: String(localized: "home.compose.addAddress", defaultValue: "Invite %@ by email", bundle: .module), address)
    }
    static func composeTo(_ names: String) -> String {
        String(format: String(localized: "home.compose.to", defaultValue: "To: %@", bundle: .module), names)
    }
    static var composeNoContacts: String {
        String(localized: "home.compose.noContacts", defaultValue: "No teammates yet. Invite someone by email.", bundle: .module)
    }
    static var inviteByEmail: String { String(localized: "home.compose.inviteByEmail", defaultValue: "Invite by Email…", bundle: .module) }
    static var sourceTeam: String { String(localized: "home.compose.source.team", defaultValue: "Team", bundle: .module) }
    static var sourceConnection: String { String(localized: "home.compose.source.connection", defaultValue: "Contact", bundle: .module) }

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

    // MARK: New Chief

    static var chiefTitle: String { String(localized: "home.chief.new.title", defaultValue: "New Chief", bundle: .module) }
    static var chiefBody: String {
        String(localized: "home.chief.new.body",
               defaultValue: "A Chief is an agent with its own conversation and memory. Chiefs are optional.", bundle: .module)
    }
    static var chiefName: String { String(localized: "home.chief.new.name", defaultValue: "Name", bundle: .module) }
    static var chiefCreate: String { String(localized: "home.chief.new.create", defaultValue: "Create", bundle: .module) }

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


    // MARK: Outcomes

    /// What the sheet says after a start or an invite; nil when it closes.
    static func outcome(_ outcome: HomeComposeOutcome) -> String? {
        switch outcome {
        case .opened: nil
        case .invited: String(localized: "home.outcome.invited", defaultValue: "Invite sent.", bundle: .module)
        case .notReachable(let name):
            String(format: String(localized: "home.outcome.notReachable",
                                  defaultValue: "You can’t message %@ yet. Invite them by email instead.", bundle: .module), name)
        case .rateLimited:
            String(localized: "home.outcome.rateLimited",
                   defaultValue: "You started too many conversations in the last hour. Try again later.", bundle: .module)
        case .mixedRecipients:
            String(localized: "home.outcome.mixed",
                   defaultValue: "A group can include people or email addresses, not both. Invite the email addresses first.",
                   bundle: .module)
        case .invalidAddress(let text):
            String(format: String(localized: "home.outcome.invalidAddress", defaultValue: "“%@” is not an email address.",
                                  bundle: .module), text)
        case .offline:
            String(localized: "home.outcome.offline", defaultValue: "You’re offline. Nothing was sent.", bundle: .module)
        case .refused(let reason) where reason.isEmpty:
            String(localized: "home.outcome.failed", defaultValue: "That didn’t work. Try again.", bundle: .module)
        case .refused(let reason):
            String(format: String(localized: "home.outcome.refused", defaultValue: "That didn’t work: %@", bundle: .module), reason)
        }
    }

    /// A refused invite's reason as the user reads it (the owner's codes).
    static func inviteRefusal(_ code: String) -> String {
        switch code {
        case "invite.blocked", "invite.recipient_limited":
            String(localized: "home.outcome.inviteBlocked", defaultValue: "This address can’t be invited right now.", bundle: .module)
        case "invite.rate_limited":
            String(localized: "home.outcome.inviteRateLimited", defaultValue: "You sent too many invites. Try again later.",
                   bundle: .module)
        case "home.not_configured":
            String(localized: "home.outcome.inviteUnavailable", defaultValue: "Invites aren’t available on this server.",
                   bundle: .module)
        default: code
        }
    }
}

extension HomeComposeOutcome {
    /// What the sheet (or a refused action) says for this outcome; nil when it closes.
    public var message: String? { HomeConversationStrings.outcome(self) }

    /// An invite or op the owner refused with `code`, as the user reads it.
    public static func refusal(code: String) -> HomeComposeOutcome { .refused(HomeConversationStrings.inviteRefusal(code)) }
}
