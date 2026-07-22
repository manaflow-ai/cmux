import Foundation

/// A bounded transcript suffix with stable absolute byte positions for its lines.
struct AgentChatTranscriptSlice {
    let data: Data
    let lineStartOffsets: [UInt64]
    let transcriptExtent: UInt64
}
