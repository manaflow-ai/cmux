public import CmuxNextDaemon
public import Foundation

/// The Chief conversation's notice when the person's last message has had no reply
/// for over two minutes and the Chief's brain is not running (user 2026-10-21: "make
/// every user message in the Chief DM get a reply, guaranteed"). A running brain
/// retries a turn that left a message unanswered and posts its own failure note,
/// with the reason, after its retries (optchat-chief brain/reply_ledger.rs), so a
/// slow reply from a running brain shows nothing (Leo, 2026-11-03: "don't fucking show
/// no response from model"); this rule covers a brain that died or never started.
public nonisolated struct ChiefReplyWatchdog {
    public nonisolated init() {}
    /// How long a person's message may wait before Home says so.
    public static let limit: TimeInterval = 120

    /// When the person's unanswered message arrived: the head is a person's
    /// text (not a Chief's or another agent's), nil when it is answered.
    public static func waitingSince(_ summary: ConversationSummary) -> Date? {
        guard let last = summary.lastMessage, last.retractedAt == nil else { return nil }
        let author = summary.participants.first { $0.id == last.author }
        // An unknown author is a person the head does not list yet; an agent never waits,
        // nor does another agent's message posted through `cmux chief -p --from`
        // (`agent~` client ids, cmux-conversation agent_sender.rs): its sender hears back
        // on its own channel.
        guard author?.kind != .agent, !last.author.hasPrefix("agent_"),
              !last.clientMsgID.hasPrefix(agentSenderMark) else { return nil }
        return date(last.createdAt)
    }

    /// The `client_msg_id` prefix of another agent's message (cmux-conversation `MARK`).
    static let agentSenderMark = "agent~"

    /// The notice at `now`: nil while nothing waits past `limit`, and nil while the
    /// Chief's brain runs (`brainRunning`, read only past `limit`), which answers or says
    /// why it cannot.
    public static func notice(_ summary: ConversationSummary, now: Date,
                              brainRunning: @autoclosure () -> Bool) -> String? {
        guard let since = waitingSince(summary), now.timeIntervalSince(since) >= limit,
              !brainRunning() else { return nil }
        return HomeStrings.chiefNotRunning
    }

    /// When to look again (at `limit`, then each minute, for a brain that stops while
    /// the message waits), nil when nothing waits.
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
