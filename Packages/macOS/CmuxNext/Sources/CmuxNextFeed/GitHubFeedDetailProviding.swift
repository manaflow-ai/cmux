import Foundation

/// Provides live, client-only GitHub detail for inbox rendering.
@MainActor
public protocol GitHubFeedDetailProviding: AnyObject {
    var githubDetails: [String: GitHubFeedDetail] { get }
    func githubDetail(for item: FeedItem) -> GitHubFeedDetail?
}
