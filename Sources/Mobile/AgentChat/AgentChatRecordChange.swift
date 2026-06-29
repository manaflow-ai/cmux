import Foundation

/// A single record-change event mirrored from `AgentChatSessionRegistry.onRecordChanged`, exposed
/// as a Combine publisher so multiple consumers (e.g. the sidebar bridge) can subscribe — the
/// `onRecordChanged` closure is a single-owner slot already held by AgentChatTranscriptService.
struct AgentChatRecordChange: Sendable {
    let record: AgentChatSessionRecord
    let previous: AgentChatSessionRecord?
}
