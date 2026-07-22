import Foundation

/// A bounded transcript suffix with its stable absolute line position.
struct AgentChatTranscriptSlice {
    let data: Data
    let startOffset: UInt64
    let startingSequence: Int
}
