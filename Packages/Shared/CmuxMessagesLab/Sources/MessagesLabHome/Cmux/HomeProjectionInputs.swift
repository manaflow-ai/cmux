import CmuxHomeCore

/// One conversation's part of HomeStore that `HomeProjection.refresh` reads.
///
/// HomeStore keeps typing, running replies, live runs and transcript versions
/// as dictionaries over every conversation, and Observation tracks a
/// dictionary as one property: a frame from any agent's conversation wakes
/// every open transcript. Comparing this value first lets the Chief's
/// transcript sleep through other conversations' traffic (with ~100 agents
/// streaming, hundreds of passes a second that each rebuilt and compared the
/// whole window on the main thread, between the user's keys).
struct HomeProjectionInputs: Equatable {
    var me: ParticipantID?
    var transcriptVersion: Int
    var summary: ConversationSummary?
    var row: InboxRow?
    var typing: Set<ParticipantID>?
    var streams: [HomeStreamRow]
    var live: HomeLiveRun?
    var confirmed: Bool
    var hasOlder: Bool

    /// Reads `conversation`'s inputs; every read is a constant-time lookup except the row (one pass over the inbox).
    @MainActor
    init(_ store: HomeStore, _ conversation: ConversationID) {
        me = store.me?.id
        transcriptVersion = store.transcriptVersion[conversation, default: 0]
        summary = store.summary(conversation)
        row = store.rows.first { $0.summary.id == conversation }
        typing = store.typing.value(for: conversation)
        streams = store.streams(in: conversation)
        live = store.liveRun(in: conversation)
        confirmed = store.isConfirmed(conversation)
        hasOlder = store.hasOlderMessages(in: conversation)
    }
}
