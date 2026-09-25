import Foundation

/// Deduplicates one authenticated REST or GraphQL request and its conditional cache.
struct GitHubPullRequestRequestKey: Hashable, Sendable {
    let endpoint: String
    let body: Data?
    let authorizationFingerprint: Data
    let rateLimitResource: RateLimitResource
}
