import CmuxHomeCore
import Foundation

extension Date {
    /// Messages' list time: the time today, "Yesterday", the weekday within
    /// the last week, else the short date (the locale's own words and order).
    func homeListTime(now: Date, calendar: Calendar, locale: Locale) -> String {
        guard self > .distantPast else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if calendar.isDate(self, inSameDayAs: now) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: self)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: self)
        }
        if (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: self)
        }
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }
}

/// A row's preview: the newest message, or a reaction to it.
struct HomeRowPreview: Hashable {
    var text: String
    var isReply: Bool
}

extension InboxRow {
    /// The newest message's text; when someone reacted to it, the reaction
    /// ("Lucas loved “Good luck!”"); a reply keeps its text and says so.
    func homePreview(me: ParticipantID?) -> HomeRowPreview {
        let text = preview.replacingOccurrences(of: "\n", with: " ")
        guard let last = summary.lastMessage, last.retractedAt == nil else { return HomeRowPreview(text: text, isReply: false) }
        if let reaction = last.reactions.last {
            let who = reaction.author == me ? HomeConversationStrings.you
                : (summary.participants.first { $0.id == reaction.author }?.displayName ?? "")
            let quoted = last.plainText.replacingOccurrences(of: "\n", with: " ")
            return HomeRowPreview(text: HomeConversationStrings.reaction(reaction.kind, by: who, to: quoted), isReply: false)
        }
        return HomeRowPreview(text: text, isReply: last.replyTo != nil)
    }
}
