#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// One visual row of the transcript.
enum ConversationRow: Hashable {
    case conversationStart
    case loadingOlder
    case timestamp(id: String, date: Date)
    case message(MessageRowModel)
    case typing(participantIDs: [String])

    var id: String {
        switch self {
        case .conversationStart: return "start"
        case .loadingOlder: return "loading"
        case let .timestamp(id, _): return id
        case let .message(model): return model.rowID
        case .typing: return "typing"
        }
    }
}

struct ReplyQuote: Hashable {
    var text: String
    var isOutgoing: Bool
    var hasImage: Bool
}

enum MessageFooter: Hashable {
    case none
    case status(String)
    case notDelivered
}

struct MessageRowModel: Hashable {
    var rowID: String
    var message: ConversationMessage
    var isOutgoing: Bool
    var senderName: String?
    var senderInitials: String
    var senderColorHex: String
    var showsSenderName: Bool
    var showsAvatar: Bool
    /// Leaves room for an avatar column (group chats, incoming).
    var reservesAvatarColumn: Bool
    var isGroup: Bool
    var showsTail: Bool
    var isFirstInGroup: Bool
    var footer: MessageFooter
    var replyQuote: ReplyQuote?
    var isEmojiOnly: Bool
    /// Distinct tapbacks in first-given order, and whether one of them is mine.
    var reactionKinds: [ConversationReaction]
    var hasMyReaction: Bool
}

/// Builds rows from store state with Messages grouping rules: consecutive
/// messages from one sender group (tail on the last), a timestamp separates
/// gaps of an hour, sender names and avatars appear only in group chats.
@MainActor
enum ConversationRowBuilder {
    static func rows(
        store: ConversationStore,
        hidesLoadingRow: Bool = false
    ) -> [ConversationRow] {
        guard let info = store.info else { return [] }
        var rows: [ConversationRow] = []
        rows.reserveCapacity(store.messages.count * 2 + 3)
        if store.older == .exhausted {
            rows.append(.conversationStart)
        } else if store.hasLoadedNewest, !hidesLoadingRow {
            rows.append(.loadingOlder)
        }
        let isGroup = info.kind == .group
        let messages = store.messages
        let meID = store.meID
        let lastOutgoingAcked = messages.lastIndex { $0.senderID == meID && $0.seq != nil }
        let typingIDs = store.typingParticipantIDs

        var previous: ConversationMessage?
        for (index, message) in messages.enumerated() {
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let needsTimestamp = previous.map { message.sentAt.timeIntervalSince($0.sentAt) >= ConversationTheme.timestampGap } ?? true
            if needsTimestamp {
                rows.append(.timestamp(id: "ts:\(message.rowID)", date: message.sentAt))
            }
            let groupedWithPrevious = !needsTimestamp && previous.map { sameGroup($0, message) } ?? false
            let nextBreaksGroup: Bool = {
                guard let next else {
                    // A typing bubble from the same sender continues the group visually.
                    return !(typingIDs.contains(message.senderID))
                }
                if next.sentAt.timeIntervalSince(message.sentAt) >= ConversationTheme.timestampGap { return true }
                return !sameGroup(message, next)
            }()
            let isOutgoing = message.senderID == meID
            let sender = info.participant(message.senderID)
            let footer: MessageFooter
            if message.delivery?.isFailed == true {
                footer = .notDelivered
            } else if isOutgoing, index == lastOutgoingAcked || (message.seq == nil && index == messages.count - 1 && lastOutgoingAcked == nil) {
                footer = statusFooter(message.delivery, isGroup: isGroup)
            } else {
                footer = .none
            }
            let quote = message.replyToID.flatMap { store.message(id: $0) }.map {
                ReplyQuote(text: $0.text.isEmpty ? "Photo" : $0.text, isOutgoing: $0.senderID == meID, hasImage: !$0.attachments.isEmpty)
            }
            rows.append(.message(MessageRowModel(
                rowID: message.rowID,
                message: message,
                isOutgoing: isOutgoing,
                senderName: sender?.name,
                senderInitials: sender?.initials ?? "",
                senderColorHex: sender?.colorHex ?? "#8E8E93",
                showsSenderName: isGroup && !isOutgoing && (!groupedWithPrevious || quote != nil),
                showsAvatar: isGroup && !isOutgoing && nextBreaksGroup,
                reservesAvatarColumn: isGroup && !isOutgoing,
                isGroup: isGroup,
                showsTail: nextBreaksGroup || quote != nil || footer != .none,
                isFirstInGroup: !groupedWithPrevious,
                footer: footer,
                replyQuote: quote,
                isEmojiOnly: message.attachments.isEmpty && isEmojiOnly(message.text),
                reactionKinds: message.reactions.reduce(into: [ConversationReaction]()) { kinds, mark in
                    if !kinds.contains(mark.reaction) { kinds.append(mark.reaction) }
                },
                hasMyReaction: message.reactions.contains { $0.participantID == meID }
            )))
            previous = message
        }
        if !typingIDs.isEmpty {
            rows.append(.typing(participantIDs: typingIDs))
        }
        return rows
    }

    private static func sameGroup(_ a: ConversationMessage, _ b: ConversationMessage) -> Bool {
        a.senderID == b.senderID && b.sentAt.timeIntervalSince(a.sentAt) < 5 * 60 && b.replyToID == nil
    }

    private static func statusFooter(_ delivery: ConversationDelivery?, isGroup: Bool) -> MessageFooter {
        switch delivery {
        case .delivered:
            return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
        case let .read(date):
            guard !isGroup else {
                return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
            }
            if let date {
                let time = date.formatted(date: .omitted, time: .shortened)
                return .status(String(
                    format: String(localized: "conversation.status.readAt", defaultValue: "Read %@", bundle: .module),
                    time
                ))
            }
            return .status(String(localized: "conversation.status.read", defaultValue: "Read", bundle: .module))
        case .sent, .sending, nil:
            return .none
        case .failed:
            return .notDelivered
        }
    }

    /// One to three emoji and nothing else render large without a bubble.
    static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }
}
#endif
