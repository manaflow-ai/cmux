import Foundation

/// GitHub API resource whose primary quota is independently enforced.
enum RateLimitResource: Hashable, Sendable {
    case rest
    case graphql
}

/// Rate-limit scope shared by REST and GraphQL secondary backoff.
enum RateLimitScope: Hashable, Sendable {
    case primary(RateLimitResource)
    case secondary
}

/// Credential and scope key for bounded rate-limit deadlines.
struct RateLimitKey: Hashable, Sendable {
    let authorizationFingerprint: Data
    let scope: RateLimitScope
}
