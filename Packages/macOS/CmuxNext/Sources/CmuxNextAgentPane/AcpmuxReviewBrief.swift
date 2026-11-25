public import Foundation

/// A chat's review brief (`_acpmux/review_brief`, acpmux `review_brief.rs`): what it set out to
/// do, what it dropped and where it was unsure, which the diff tab of its worktree shows. acpmux
/// keeps it beside the chat's log, so a read costs only what the chat logged since the last one.
public nonisolated struct AcpmuxReviewBrief: Sendable {
    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    /// The answer (`{sessionId, seq, brief}`) as JSON for `session`, its paths relative to `root`.
    @concurrent public func read(session: String, root: String) async throws -> Data {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/review_brief",
                                                       params: ["sessionId": session, "root": root],
                                                       deadline: AcpmuxEnvironment.answerDeadline)
        return try JSONSerialization.data(withJSONObject: result)
    }
}
