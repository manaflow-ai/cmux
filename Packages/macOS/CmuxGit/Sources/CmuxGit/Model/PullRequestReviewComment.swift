import Foundation

/// A review comment decoded from `gh pr view <number> --json comments`.
struct PullRequestReviewComment: Decodable, Equatable, Sendable {
    /// The review-thread identifier, when the GitHub CLI payload exposes it.
    let threadId: String?

    /// Whether the associated review thread is resolved, when exposed.
    let isResolved: Bool?

    private enum CodingKeys: String, CodingKey {
        case threadId, isResolved
    }

    /// Decodes optional review-thread metadata while accepting string or numeric thread identifiers.
    /// - Parameter decoder: The GitHub CLI comments JSON decoder.
    /// - Throws: A decoding error when exposed review-thread metadata is malformed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(String.self, forKey: .threadId) {
            threadId = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .threadId) {
            threadId = String(value)
        } else {
            threadId = nil
        }
        isResolved = try container.decodeIfPresent(Bool.self, forKey: .isResolved)
    }

    /// Creates review-thread metadata.
    /// - Parameters:
    ///   - threadId: The review-thread identifier.
    ///   - isResolved: Whether the thread is resolved.
    init(threadId: String?, isResolved: Bool?) {
        self.threadId = threadId
        self.isResolved = isResolved
    }
}
