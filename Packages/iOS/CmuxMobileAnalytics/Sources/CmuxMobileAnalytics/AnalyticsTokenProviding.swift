public import Foundation

/// Supplies the Stack auth tokens the analytics proxy requires.
///
/// The analytics package must not depend on `CmuxAuthRuntime`, so the bearer +
/// refresh tokens are injected through this seam. The composition root bridges
/// it to the `AuthCoordinator` (which already conforms to the auth package's own
/// `TokenProviding`). Pre-auth events still capture and buffer; they upload once
/// a token is available, or are dropped by the proxy if it requires auth.
public protocol AnalyticsTokenProviding: Sendable {
    /// The current short-lived access token, or `nil` if unavailable (signed out).
    func accessToken() async -> String?
    /// The current refresh token, or `nil` if unavailable.
    func refreshToken() async -> String?
}

/// An always-anonymous token provider that supplies no credentials.
///
/// Used in previews/tests and as a safe default before sign-in wiring exists.
public struct AnonymousAnalyticsTokenProvider: AnalyticsTokenProviding {
    /// Creates an anonymous provider.
    public init() {}
    public func accessToken() async -> String? { nil }
    public func refreshToken() async -> String? { nil }
}
