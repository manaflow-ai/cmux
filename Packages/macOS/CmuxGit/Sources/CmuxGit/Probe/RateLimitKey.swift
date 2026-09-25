import Foundation

/// Credential and scope key for bounded rate-limit deadlines.
struct RateLimitKey: Hashable, Sendable {
    let authorizationFingerprint: Data
    let scope: RateLimitScope
}
