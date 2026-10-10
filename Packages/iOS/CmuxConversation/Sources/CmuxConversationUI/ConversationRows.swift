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
        } else if store.hasLoadedNewest, !hidesLoadingRow, store.older != .idle {
            // Spinner only while an older page is in flight (or retrying).
            rows.append(.loadingOlder)
        }
        let isGroup = info.kind == .group
        let messages = store.messages
        let meID = store.meID
        let typingIDs = store.typingParticipantIDs

        let plan = ConversationRunPlan(messages: messages, meID: meID, typingParticipantIDs: typingIDs)
        for (index, message) in messages.enumerated() {
            let entry = plan.entries[index]
            if entry.showsTimestamp {
                rows.append(.timestamp(id: "ts:\(message.rowID)", date: message.sentAt))
            }
            let groupedWithPrevious = !entry.isFirstInRun
            let nextBreaksGroup = entry.isLastInRun
            let isOutgoing = message.senderID == meID
            let sender = info.participant(message.senderID)
            let footer = footer(for: entry.status, isGroup: isGroup)
            let quote = message.replyToID.flatMap { store.message(id: $0) }.map {
                ReplyQuote(text: $0.text.isEmpty ? String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module) : $0.text, isOutgoing: $0.senderID == meID, hasImage: !$0.attachments.isEmpty)
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
                showsTail: nextBreaksGroup || quote != nil,
                isFirstInGroup: !groupedWithPrevious,
                footer: footer,
                replyQuote: quote,
                isEmojiOnly: message.attachments.isEmpty && isEmojiOnly(message.text),
                reactionKinds: message.reactions.reduce(into: [ConversationReaction]()) { kinds, mark in
                    if !kinds.contains(mark.reaction) { kinds.append(mark.reaction) }
                },
                hasMyReaction: message.reactions.contains { $0.participantID == meID }
            )))
        }
        if !typingIDs.isEmpty {
            rows.append(.typing(participantIDs: typingIDs))
        }
        return rows
    }

    private static func footer(for status: ConversationRunPlan.Status, isGroup: Bool) -> MessageFooter {
        switch status {
        case .none:
            return .none
        case .notDelivered:
            return .notDelivered
        case .delivered:
            return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
        case let .read(date):
            // Group chats never expose read state.
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
