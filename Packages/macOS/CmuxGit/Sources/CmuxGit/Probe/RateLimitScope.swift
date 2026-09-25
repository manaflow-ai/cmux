import Foundation

/// Rate-limit scope shared by REST and GraphQL secondary backoff.
enum RateLimitScope: Hashable, Sendable {
    case primary(RateLimitResource)
    case secondary
}
