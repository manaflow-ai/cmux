import Foundation

/// Strings of the feed panel (Resources/Localizable.xcstrings). Few labels
/// by design: glyphs carry kind and state, posters carry their own text.
nonisolated enum FeedStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("feed.title", "Feed") }
    static var empty: String { t("feed.empty", "Nothing new") }
    static var menubarEmpty: String { t("menubar.empty", "No open requests") }
    static var openFeed: String { t("menubar.openFeed", "Open Feed") }
    static var markAllRead: String { t("feed.markAllRead", "Mark All Read") }
    static var github: String { t("feed.github", "GitHub") }
    static var addConnection: String { t("feed.addConnection", "Add connection") }
    static var filterInbox: String { t("feed.filterInbox", "Filter inbox") }
    static var allItems: String { t("feed.allItems", "All items") }
    static var unread: String { t("feed.unread", "Unread") }
    static var notices: String { t("feed.notices", "Notices") }
    static var refresh: String { t("feed.refresh", "Refresh") }
    static var noMatches: String { t("feed.noMatches", "No matching items") }
    static var selectInboxItem: String { t("feed.selectInboxItem", "Select an inbox item") }
    static var githubActions: String { t("feed.githubActions", "GitHub actions") }
    static var openOnGitHub: String { t("feed.openOnGitHub", "Open on GitHub") }
    static var checkout: String { t("feed.checkout", "Check out") }
    static var startAgent: String { t("feed.startAgent", "Start agent") }
    static var comment: String { t("feed.comment", "Comment") }

    static var needsYou: String { t("group.needsYou", "Needs you") }
    static var today: String { t("group.today", "Today") }
    static var earlier: String { t("group.earlier", "Earlier") }

    static var allow: String { t("answer.allow", "Allow") }
    static var deny: String { t("answer.deny", "Deny") }
    static var decline: String { t("answer.decline", "Decline") }
    static var send: String { t("answer.send", "Send") }
    static var approve: String { t("answer.approve", "Approve") }
    static var requestChanges: String { t("answer.requestChanges", "Request Changes") }
    static var confirm: String { t("answer.confirm", "Confirm") }
    static var signIn: String { t("answer.signIn", "Sign In") }
    static var usePasskey: String { t("answer.usePasskey", "Use Passkey") }
    static var takeOver: String { t("answer.takeOver", "Take Over") }
    static var chooseFile: String { t("answer.chooseFile", "Choose File") }
    static var open: String { t("answer.open", "Open") }
    static var reply: String { t("answer.reply", "Reply") }
    static var other: String { t("answer.other", "Other") }
    static var pickOne: String { t("answer.pickOne", "Answer each question") }

    static var done: String { t("toolbar.done", "Done") }
    static var snooze: String { t("toolbar.snooze", "Snooze") }
    static var snoozeHour: String { t("toolbar.snoozeHour", "For 1 Hour") }
    static var snoozeTomorrow: String { t("toolbar.snoozeTomorrow", "Until Tomorrow") }

    static var thisMac: String { t("item.thisMac", "This Mac only") }
    static var declined: String { t("item.declined", "Declined") }
    static var cancelled: String { t("item.cancelled", "Cancelled") }
    static var expired: String { t("item.expired", "Expired") }
    static var answeredInTerminal: String { t("item.answeredInTerminal", "Answered in the terminal") }
    static func answeredOn(_ device: String) -> String { t("item.answeredOn", "Answered on \(device)") }
    static func threadCount(_ count: Int) -> String { t("item.threadCount", "\(count) items") }

    static var disconnected: String { t("owner.disconnected", "Feed is unreachable") }
    static var moving: String { t("owner.moving", "Moving to the cloud. Try again.") }
    static var refused: String { t("owner.refused", "The feed refused the change") }

    static func scope(_ scope: FeedApproveScope) -> String {
        switch scope {
        case .once: t("scope.once", "Once")
        case .session: t("scope.session", "This session")
        case .always: t("scope.always", "Always")
        }
    }

    /// The closed state of a request, for its row and the late-answer notice.
    static func closed(_ item: FeedItem) -> String? {
        switch item.state {
        case .open: nil
        case .answered: answeredOn(item.answer?.device ?? "")
        case .expired: expired
        case .cancelled:
            switch item.cancel?.reason {
            case .declined: declined
            case .answeredElsewhere: answeredInTerminal
            default: cancelled
            }
        }
    }

    static func reject(_ reject: FeedReject) -> String {
        switch reject {
        case let .closed(item): closed(item) ?? refused
        case .moving: moving
        case .disconnected: disconnected
        case .invalid, .other: refused
        }
    }
}
