import Foundation

/// A group change Messages records in the transcript as a centered status
/// row ("Lawrence Chen named the conversation “cmux”."). It rides on a
/// `ConversationMessage` (seq, paging and dedupe stay the same); the
/// message's `senderID` is who made the change.
public struct ConversationSystemEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `name` is the new conversation name.
        case named
        case removedName
        /// `targetID` joined.
        case added
        /// `targetID` was removed by the actor.
        case removed
        case left
        case changedPhoto
        case removedPhoto
        /// "Leo changed the background." (`GROUP_UPDATE_BACKGROUND_STATUS`)
        case changedBackground
        /// "Leo removed the background." (`GROUP_DELETE_BACKGROUND_STATUS`)
        case removedBackground
    }

    public var kind: Kind
    /// The added or removed participant.
    public var targetID: String?
    /// The new conversation name (`named`).
    public var name: String?

    public init(kind: Kind, targetID: String? = nil, name: String? = nil) {
        self.kind = kind
        self.targetID = targetID
        self.name = name
    }
}

/// A status line ready to draw: plain text plus the ranges ChatKit sets in
/// the emphasized weight (the `#…#` spans of its GROUP_*_STATUS strings: the
/// actor's name, or "You").
public struct ConversationSystemText: Sendable, Hashable {
    public var text: String
    /// UTF-16 ranges of `text`.
    public var emphasized: [NSRange]

    public init(text: String, emphasized: [NSRange] = []) {
        self.text = text
        self.emphasized = emphasized
    }

    /// Builds the text from a ChatKit-style template: `#` delimits an
    /// emphasized span; `%1$@`, `%2$@` and `%@` take `arguments` in order.
    /// Arguments are substituted after the `#` split, so a name containing
    /// `#` cannot open or close a span.
    public static func formatted(_ template: String, _ arguments: [String]) -> ConversationSystemText {
        var text = ""
        var emphasized: [NSRange] = []
        var sequential = 0
        for (index, segment) in template.components(separatedBy: "#").enumerated() {
            var piece = ""
            var rest = Substring(segment)
            while let percent = rest.firstIndex(of: "%") {
                piece += rest[..<percent]
                let tail = rest[percent...]
                if let match = tail.prefixMatch(positional: arguments.count) {
                    piece += arguments[match.index]
                    rest = tail.dropFirst(match.length)
                } else if tail.hasPrefix("%@") {
                    piece += sequential < arguments.count ? arguments[sequential] : ""
                    sequential += 1
                    rest = tail.dropFirst(2)
                } else {
                    piece += "%"
                    rest = tail.dropFirst()
                }
            }
            piece += rest
            let start = (text as NSString).length
            text += piece
            // Odd segments sit between a pair of `#`.
            if index % 2 == 1, !piece.isEmpty {
                emphasized.append(NSRange(location: start, length: (piece as NSString).length))
            }
        }
        return ConversationSystemText(text: text, emphasized: emphasized)
    }
}

private extension Substring {
    /// `%N$@` at the start, with N in 1...count.
    func prefixMatch(positional count: Int) -> (index: Int, length: Int)? {
        guard hasPrefix("%"), let dollar = firstIndex(of: "$"),
              let number = Int(self[index(after: startIndex)..<dollar]), (1...count).contains(number),
              self[dollar...].hasPrefix("$@") else { return nil }
        return (number - 1, distance(from: startIndex, to: dollar) + 2)
    }
}

/// Messages' wording for status rows and notification-state notices,
/// shared by the iOS and macOS transcripts (ChatKit strings, en and ja).
public enum ConversationStatusStrings {
    /// The status line for `message.systemEvent`, or nil for a plain message.
    /// Names are participants' display names; I am "You".
    public static func text(for message: ConversationMessage, meID: String?, info: ConversationInfo) -> ConversationSystemText? {
        guard let event = message.systemEvent else { return nil }
        let actorIsMe = message.senderID == meID
        let actor = info.participant(message.senderID)?.name ?? message.senderID
        let targetIsMe = event.targetID != nil && event.targetID == meID
        let target = event.targetID.map { info.participant($0)?.name ?? $0 } ?? ""
        let template: String
        var arguments: [String] = []
        switch event.kind {
        case .named:
            let name = event.name ?? ""
            if actorIsMe {
                template = String(localized: "conversation.system.named.you", defaultValue: "#You# named the conversation “%@”.", bundle: .module)
                arguments = [name]
            } else {
                template = String(localized: "conversation.system.named", defaultValue: "#%1$@# named the conversation “%2$@”.", bundle: .module)
                arguments = [actor, name]
            }
        case .removedName:
            if actorIsMe {
                template = String(localized: "conversation.system.removedName.you", defaultValue: "#You# removed the name from the conversation.", bundle: .module)
            } else {
                template = String(localized: "conversation.system.removedName", defaultValue: "#%1$@# removed the name from the conversation.", bundle: .module)
                arguments = [actor]
            }
        case .added:
            if actorIsMe {
                template = String(localized: "conversation.system.added.byYou", defaultValue: "#You# added %@ to the conversation.", bundle: .module)
                arguments = [target]
            } else if targetIsMe {
                template = String(localized: "conversation.system.added.you", defaultValue: "#%@# added you to the conversation.", bundle: .module)
                arguments = [actor]
            } else {
                template = String(localized: "conversation.system.added", defaultValue: "#%1$@# added %2$@ to the conversation.", bundle: .module)
                arguments = [actor, target]
            }
        case .removed:
            if actorIsMe {
                template = String(localized: "conversation.system.removed.byYou", defaultValue: "#You# removed %@ from the conversation.", bundle: .module)
                arguments = [target]
            } else if targetIsMe {
                template = String(localized: "conversation.system.removed.you", defaultValue: "#%@# removed you from the conversation.", bundle: .module)
                arguments = [actor]
            } else {
                template = String(localized: "conversation.system.removed", defaultValue: "#%1$@# removed %2$@ from the conversation.", bundle: .module)
                arguments = [actor, target]
            }
        case .left:
            if actorIsMe {
                template = String(localized: "conversation.system.left.you", defaultValue: "#You# left the conversation.", bundle: .module)
            } else {
                template = String(localized: "conversation.system.left", defaultValue: "#%@# left the conversation.", bundle: .module)
                arguments = [actor]
            }
        case .changedPhoto:
            if actorIsMe {
                template = String(localized: "conversation.system.changedPhoto.you", defaultValue: "#You# changed the group photo.", bundle: .module)
            } else {
                template = String(localized: "conversation.system.changedPhoto", defaultValue: "#%@# changed the group photo.", bundle: .module)
                arguments = [actor]
            }
        case .removedPhoto:
            if actorIsMe {
                template = String(localized: "conversation.system.removedPhoto.you", defaultValue: "#You# removed the group photo.", bundle: .module)
            } else {
                template = String(localized: "conversation.system.removedPhoto", defaultValue: "#%@# removed the group photo.", bundle: .module)
                arguments = [actor]
            }
        case .changedBackground:
            if actorIsMe {
                template = String(localized: "conversation.background.notice.youChanged", defaultValue: "#You# changed the background.", bundle: .module)
            } else {
                template = String(localized: "conversation.background.notice.changed", defaultValue: "#%@# changed the background.", bundle: .module)
                arguments = [actor]
            }
        case .removedBackground:
            if actorIsMe {
                template = String(localized: "conversation.background.notice.youRemoved", defaultValue: "#You# removed the background.", bundle: .module)
            } else {
                template = String(localized: "conversation.background.notice.removed", defaultValue: "#%@# removed the background.", bundle: .module)
                arguments = [actor]
            }
        }
        return .formatted(template, arguments)
    }

    /// MESSAGE_STATUS_DELIVERED_QUIETLY.
    public static var deliveredQuietly: String {
        String(localized: "conversation.status.deliveredQuietly", defaultValue: "Delivered Quietly", bundle: .module)
    }

    /// UNAVAILABILITY_INDICATOR_TITLE_FORMAT, with the person's first name.
    public static func notificationsSilenced(_ name: String) -> String {
        String(format: String(localized: "conversation.unavailability.silenced", defaultValue: "%@ has notifications silenced", bundle: .module), name)
    }

    /// NOTIFY_ANYWAY_BUTTON_TITLE.
    public static var notifyAnyway: String {
        String(localized: "conversation.unavailability.notifyAnyway", defaultValue: "Notify Anyway", bundle: .module)
    }

    /// CONVERSATION_LIST_EMPTY: the conversation list has nothing at all.
    public static var noConversations: String {
        String(localized: "conversation.list.empty", defaultValue: "No Conversations", bundle: .module)
    }

    /// NO_MESSAGES: a filtered list with nothing in it.
    public static var noMessages: String {
        String(localized: "conversation.list.noMessages", defaultValue: "No Messages", bundle: .module)
    }

    /// NO_UNREAD_MESSAGES_DESCRIPTION.
    public static var noUnreadDescription: String {
        String(localized: "conversation.list.noUnread.description", defaultValue: "Messages that are unread will appear here.", bundle: .module)
    }

    /// ALL_MESSAGES (filter menu).
    public static var allMessages: String {
        String(localized: "conversation.list.filter.all", defaultValue: "All Messages", bundle: .module)
    }

    /// UNREAD_MESSAGES (filter menu).
    public static var unreadMessages: String {
        String(localized: "conversation.list.filter.unread", defaultValue: "Unread Messages", bundle: .module)
    }

    /// NO_CONVERSATION_SELECTED (macOS transcript pane).
    public static var noConversationSelected: String {
        String(localized: "conversation.list.noSelection", defaultValue: "No Conversation Selected", bundle: .module)
    }
}

extension ConversationInfo {
    /// The other person in a direct conversation while their Focus silences
    /// notifications. Group conversations show no indicator.
    public var silencedRecipient: ConversationParticipant? {
        guard kind == .direct else { return nil }
        let others = participants.filter { !$0.isMe }
        guard others.count == 1, let other = others.first, other.notificationsSilenced else { return nil }
        return other
    }
}
