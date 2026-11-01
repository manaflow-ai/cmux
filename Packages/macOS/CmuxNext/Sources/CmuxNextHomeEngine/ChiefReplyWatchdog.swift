public import CmuxNextDaemon
public import Foundation

/// The Chief conversation's notice when the person's last message has no reply
/// for over two minutes (user 2026-10-21: "make every user message in the Chief
/// DM get a reply, guaranteed"). The host retries a turn that left a message
/// unanswered and posts a failure note after its retries (optchat-chief
/// brain/reply_ledger.rs); this rule needs only the conversation's head, so it
/// also covers a host that died or never got the message.
public nonisolated struct ChiefReplyWatchdog {
    public nonisolated init() {}
    /// How long a person's message may wait before Home says so.
    public static let limit: TimeInterval = 120

    /// When the person's unanswered message arrived: the head is a person's
    /// text (not a Chief's or another agent's), nil when it is answered.
    public static func waitingSince(_ summary: ConversationSummary) -> Date? {
        guard let last = summary.lastMessage, last.retractedAt == nil else { return nil }
        let author = summary.participants.first { $0.id == last.author }
        // An unknown author is a person the head does not list yet; an agent never waits.
        guard author?.kind != .agent, !last.author.hasPrefix("agent_") else { return nil }
        return date(last.createdAt)
    }

    /// The notice at `now`, nil while nothing waits past `limit`.
    public static func notice(_ summary: ConversationSummary, now: Date) -> String? {
        guard let since = waitingSince(summary) else { return nil }
        let waited = now.timeIntervalSince(since)
        guard waited >= limit else { return nil }
        return HomeStrings.chiefNoReply(minutes: Int(waited / 60))
    }

    /// When the notice next changes (it appears at `limit`, then counts the
    /// minutes), nil when nothing waits.
    public static func nextCheck(_ summary: ConversationSummary, now: Date) -> Date? {
        guard let since = waitingSince(summary) else { return nil }
        let appear = since.addingTimeInterval(limit)
        if now < appear { return appear }
        let minutes = (now.timeIntervalSince(since) / 60).rounded(.down) + 1
        return since.addingTimeInterval(minutes * 60)
    }

    /// RFC 3339 UTC, with or without milliseconds (the owner writes them).
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
