public import CmuxNextDaemon
import CmuxNextHomeModel
public import Foundation

/// The Chief conversation's notice when the person's last message has had no reply
/// for over two minutes and the Chief's brain is not running (user 2026-10-21: "make
/// every user message in the Chief DM get a reply, guaranteed"). A running brain
/// retries a turn that left a message unanswered and posts its own failure note,
/// with the reason, after its retries (optchat-chief brain/reply_ledger.rs), so a
/// slow reply from a running brain shows nothing (Leo, 2026-11-03: "don't fucking show
/// no response from model"); this rule covers a brain that died or never started.
///
/// The rule (who waits, the limit, when to look again) is `chief_brain.reply_watchdog` in
/// cmux-home-rules; this type reads the brain only past the limit, as before.
public nonisolated struct ChiefReplyWatchdog {
    public nonisolated init() {}
    /// How long a person's message may wait before Home says so (the rules' `REPLY_LIMIT_SECS`).
    public static let limit: TimeInterval = 120

    /// When the person's unanswered message arrived: the head is a person's
    /// text (not a Chief's or another agent's), nil when it is answered.
    public static func waitingSince(_ summary: ConversationSummary) -> Date? {
        check(summary, now: Date(), brainRunning: nil)?.waitingSinceSecs.map(Date.init(timeIntervalSince1970:))
    }

    /// The notice at `now`: nil while nothing waits past `limit`, and nil while the
    /// Chief's brain runs (`brainRunning`, read only past `limit`), which answers or says
    /// why it cannot.
    public static func notice(_ summary: ConversationSummary, now: Date,
                              brainRunning: @autoclosure () -> Bool) -> String? {
        guard check(summary, now: now, brainRunning: nil)?.pastLimit == true,
              check(summary, now: now, brainRunning: brainRunning())?.notice == "chiefNotRunning" else { return nil }
        return HomeStrings.chiefNotRunning
    }

    /// When to look again (at `limit`, then each minute, for a brain that stops while
    /// the message waits), nil when nothing waits.
    public static func nextCheck(_ summary: ConversationSummary, now: Date) -> Date? {
        check(summary, now: now, brainRunning: nil)?.nextCheckSecs.map(Date.init(timeIntervalSince1970:))
    }

    private static func check(_ summary: ConversationSummary, now: Date, brainRunning: Bool?) -> WatchdogReply? {
        let last = summary.lastMessage.map {
            WatchdogRequest.Last(author: $0.author, clientMsgID: $0.clientMsgID, createdAt: $0.createdAt,
                                 retractedAt: $0.retractedAt)
        }
        let request = WatchdogRequest(
            summary: .init(participants: summary.participants.map { ChiefBrainParticipant(id: $0.id, kind: $0.kind.rawValue) },
                           lastMessage: last),
            nowSecs: now.timeIntervalSince1970, brainRunning: brainRunning)
        return try? HomeRules.chiefBrain("reply_watchdog", request)
    }
}

private nonisolated struct WatchdogRequest: Encodable {
    nonisolated struct Last: Encodable {
        var author: String
        var clientMsgID: String
        var createdAt: String
        var retractedAt: String?
    }

    nonisolated struct Summary: Encodable {
        var participants: [ChiefBrainParticipant]
        var lastMessage: Last?
    }

    var summary: Summary
    var nowSecs: Double
    var brainRunning: Bool?
}

private nonisolated struct WatchdogReply: Decodable {
    var waitingSinceSecs: Double?
    var pastLimit: Bool
    var notice: String?
    var nextCheckSecs: Double?
}
