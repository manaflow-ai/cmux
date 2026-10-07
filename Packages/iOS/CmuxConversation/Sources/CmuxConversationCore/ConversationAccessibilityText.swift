import Foundation

/// VoiceOver phrasing for the transcript, shared by iOS and macOS so both
/// speak a bubble the same way. Wording and order follow Messages' own
/// accessibility bundle (ChatKit): who, content, tapbacks, then the time,
/// e.g. "Your message, I can book the table, You loved this, 3:14 AM".
/// Status ("Delivered"), "Edited" and reply counts are separate elements, as
/// they are separate views below the bubble.
public enum ConversationAccessibilityText {
    /// The bubble's label.
    /// - Parameters:
    ///   - senderName: Display name of an incoming message's sender.
    ///   - reactorName: Display name for a participant id; return nil for me.
    ///   - time: Spoken time; defaults to the short time of `sentAt`.
    public static func messageLabel(
        _ message: ConversationMessage,
        isOutgoing: Bool,
        senderName: String?,
        reactorName: (String) -> String?,
        time: String? = nil
    ) -> String {
        var parts: [String] = []
        if isOutgoing {
            parts.append(String(localized: "conversation.ax.yourMessage", defaultValue: "Your message", bundle: .module))
        } else if let senderName, !senderName.isEmpty {
            parts.append(senderName)
        }
        let images = message.attachments.filter { $0.kind == .image }.count
        if images == 1 {
            parts.append(String(localized: "conversation.ax.photo", defaultValue: "Photo", bundle: .module))
        } else if images > 1 {
            parts.append(String(format: String(localized: "conversation.ax.photos", defaultValue: "%d photos", bundle: .module), images))
        }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
        for mark in message.reactions {
            parts.append(reactionPhrase(mark.reaction, by: reactorName(mark.participantID)))
        }
        parts.append(time ?? message.sentAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ", ")
    }

    /// "You loved this" / "Ana laughed at this".
    public static func reactionPhrase(_ reaction: ConversationReaction, by name: String?) -> String {
        guard let name else {
            switch reaction {
            case .heart: return String(localized: "conversation.ax.you.heart", defaultValue: "You loved this", bundle: .module)
            case .thumbsup: return String(localized: "conversation.ax.you.thumbsup", defaultValue: "You liked this", bundle: .module)
            case .thumbsdown: return String(localized: "conversation.ax.you.thumbsdown", defaultValue: "You disliked this", bundle: .module)
            case .haha: return String(localized: "conversation.ax.you.haha", defaultValue: "You laughed at this", bundle: .module)
            case .exclamation: return String(localized: "conversation.ax.you.exclamation", defaultValue: "You emphasized this", bundle: .module)
            case .question: return String(localized: "conversation.ax.you.question", defaultValue: "You questioned this", bundle: .module)
            case .emoji(let emoji):
                return String(format: String(localized: "conversation.ax.you.emoji", defaultValue: "You reacted with %@", bundle: .module), emoji)
            }
        }
        let format: String
        switch reaction {
        case .heart: format = String(localized: "conversation.ax.someone.heart", defaultValue: "%@ loved this", bundle: .module)
        case .thumbsup: format = String(localized: "conversation.ax.someone.thumbsup", defaultValue: "%@ liked this", bundle: .module)
        case .thumbsdown: format = String(localized: "conversation.ax.someone.thumbsdown", defaultValue: "%@ disliked this", bundle: .module)
        case .haha: format = String(localized: "conversation.ax.someone.haha", defaultValue: "%@ laughed at this", bundle: .module)
        case .exclamation: format = String(localized: "conversation.ax.someone.exclamation", defaultValue: "%@ emphasized this", bundle: .module)
        case .question: format = String(localized: "conversation.ax.someone.question", defaultValue: "%@ questioned this", bundle: .module)
        case .emoji(let emoji):
            return String(format: String(localized: "conversation.ax.someone.emoji", defaultValue: "%1$@ reacted with %2$@", bundle: .module), name, emoji)
        }
        return String(format: format, name)
    }

    /// The tapback's spoken name ("Heart", "Ha ha!"), used by the pickers.
    public static func tapbackName(_ reaction: ConversationReaction) -> String {
        switch reaction {
        case .heart: return String(localized: "conversation.ax.tapback.heart", defaultValue: "Heart", bundle: .module)
        case .thumbsup: return String(localized: "conversation.ax.tapback.thumbsup", defaultValue: "Thumbs up", bundle: .module)
        case .thumbsdown: return String(localized: "conversation.ax.tapback.thumbsdown", defaultValue: "Thumbs down", bundle: .module)
        case .haha: return String(localized: "conversation.ax.tapback.haha", defaultValue: "Ha ha!", bundle: .module)
        case .exclamation: return String(localized: "conversation.ax.tapback.exclamation", defaultValue: "Exclamation mark", bundle: .module)
        case .question: return String(localized: "conversation.ax.tapback.question", defaultValue: "Question mark", bundle: .module)
        // VoiceOver speaks the emoji's own name.
        case .emoji(let emoji): return emoji
        }
    }

    /// Spoken when a message from someone else lands in the open conversation.
    public static func receivedAnnouncement(senderName: String?, text: String) -> String {
        let body = [senderName, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: ", ")
        return String(format: String(localized: "conversation.ax.received", defaultValue: "Message received: %@", bundle: .module), body)
    }

    /// Custom action and hint titles shared by both platforms.
    public static var tapbackAction: String { String(localized: "conversation.ax.action.tapback", defaultValue: "Tapback", bundle: .module) }
    public static var replyAction: String { String(localized: "conversation.ax.action.reply", defaultValue: "Reply", bundle: .module) }
    public static var openThreadAction: String { String(localized: "conversation.ax.action.openThread", defaultValue: "Open Thread", bundle: .module) }
    public static var copyAction: String { String(localized: "conversation.ax.action.copy", defaultValue: "Copy", bundle: .module) }
    public static var editAction: String { String(localized: "conversation.ax.action.edit", defaultValue: "Edit", bundle: .module) }
    public static var undoSendAction: String { String(localized: "conversation.ax.action.undoSend", defaultValue: "Undo Send", bundle: .module) }
    public static var deleteAction: String { String(localized: "conversation.ax.action.delete", defaultValue: "Delete", bundle: .module) }
    public static var tryAgainAction: String { String(localized: "conversation.ax.action.tryAgain", defaultValue: "Try Again", bundle: .module) }
    public static var copiedAnnouncement: String { String(localized: "conversation.ax.copied", defaultValue: "Message copied", bundle: .module) }
    public static var sendFailure: String { String(localized: "conversation.ax.sendFailure", defaultValue: "Send failure", bundle: .module) }
    public static var transcript: String { String(localized: "conversation.ax.transcript", defaultValue: "Messages", bundle: .module) }
    public static var reactions: String { String(localized: "conversation.ax.reactions", defaultValue: "Reactions", bundle: .module) }
    public static var reactHint: String { String(localized: "conversation.ax.reactHint", defaultValue: "Double tap to react to message", bundle: .module) }
    public static var reactHintMac: String { String(localized: "conversation.ax.reactHint.mac", defaultValue: "Activate to react to message", bundle: .module) }
}
