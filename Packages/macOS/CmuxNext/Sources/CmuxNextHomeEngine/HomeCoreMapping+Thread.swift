import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// The owner's thread reads (`conversation-thread-v1`, cx-59n8.6) as the
/// shared Home core's types. `author` maps a wire participant id (the cloud
/// maps its own account to the local user; the local owner keeps the id).
nonisolated extension HomeCoreMapping {
    static func thread(_ summary: ConversationThreadSummary, author: (String) -> ParticipantID = { ParticipantID($0) }) -> ThreadSummary {
        ThreadSummary(root: MessageID(summary.root), replyCount: summary.replyCount, lastReplySeq: summary.lastReplySeq,
                      lastReplyAt: date(summary.lastReplyAt), authors: summary.authors.map(author))
    }

    static func threadPage(_ page: ConversationThread, message: (ConversationMessage) -> Message,
                           author: (String) -> ParticipantID = { ParticipantID($0) }) -> ThreadPage {
        ThreadPage(root: message(page.root), replies: page.replies.map(message), hasMore: page.hasMore,
                   summary: thread(page.thread, author: author))
    }

    /// Whether `error` says the daemon has no thread read (fall back to a history scan).
    static func lacksThreadRead(_ error: any Error) -> Bool {
        if case DaemonError.missingCapabilities = error { return true }
        return false
    }
}
