#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// DEBUG and bench builds only (`CMUX_BENCH_HOOKS`). The generated messages of a seeded
/// transcript (`HomeStore.debugSeed`). A stub: it makes no rows yet.
enum HomeSeedTranscript {
    /// Messages seq 1...`count` of `summary`'s conversation, oldest first.
    static func messages(count: Int, in summary: ConversationSummary, me: ParticipantID, image: AttachmentRef?,
                         epoch: Date) -> [Message] {
        []
    }
}
#endif
