import Foundation

/// GitHub API resource whose primary quota is independently enforced.
enum RateLimitResource: Hashable, Sendable {
    case rest
    case graphql
}
