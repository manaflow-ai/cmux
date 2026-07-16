import Foundation

/// The comments envelope returned by `gh pr view <number> --json comments`.
struct PullRequestReviewCommentsPayload: Decodable, Equatable, Sendable {
    /// Comments included in the GitHub CLI response.
    let comments: [PullRequestReviewComment]

    /// The number of distinct unresolved review threads, or `nil` for current gh issue comments.
    var unresolvedThreadCount: Int? {
        let threadedComments = comments.compactMap { comment -> (String, Bool)? in
            guard let threadId = comment.threadId,
                  let isResolved = comment.isResolved else { return nil }
            return (threadId, isResolved)
        }
        guard !threadedComments.isEmpty else { return nil }
        return Set(threadedComments.compactMap { entry in
            entry.1 ? nil : entry.0
        }).count
    }

    /// Creates a comments payload.
    /// - Parameter comments: The decoded comments.
    init(comments: [PullRequestReviewComment]) {
        self.comments = comments
    }
}
