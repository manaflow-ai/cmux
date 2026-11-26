import Foundation

extension ConversationClient {
    /// The `run.live` snapshot of `conversation`; nil from a daemon without `chief-live-v1`.
    public func live(_ conversation: String) async throws -> ChiefLiveFrame? {
        guard await connection.identity?.supports(DaemonCapability.chiefLive.rawValue) == true else { return nil }
        return try await connection.request(ConversationLiveRequest(conversation: conversation))
    }
}

extension ConversationClient {
    /// Every step of `run` (pages read on while `has_more`, stopping on cancellation or a non-advancing cursor); nil from a daemon without `conversation-runs-v1`.
    public func runRows(_ conversation: String, run: String) async throws -> ConversationRunRows? {
        guard await connection.identity?.supports(DaemonCapability.conversationRuns.rawValue) == true else { return nil }
        var all = try await connection.request(ConversationRunRequest(conversation: conversation, run: run))
        var cursor: UInt64 = 0
        while all.hasMore == true, !Task.isCancelled, let last = all.steps.compactMap(\.rev).max(), last > cursor {
            cursor = last
            let next = try await connection.request(ConversationRunRequest(conversation: conversation, run: run, afterRev: last))
            all.steps += next.steps
            all.hasMore = next.hasMore
        }
        return all
    }
}
