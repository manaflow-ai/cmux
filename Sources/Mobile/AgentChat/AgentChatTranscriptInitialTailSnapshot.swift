import Foundation

/// Immutable result of one bounded transcript-tail read.
struct AgentChatTranscriptInitialTailSnapshot: Sendable {
    let data: Data
    let fileSize: UInt64
    let retainedStartOffset: UInt64
    let headTruncated: Bool
    let discardsUntilNextNewline: Bool
}
