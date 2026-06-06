import Foundation

/// Launch-time inputs that steer ``AuthCoordinator`` session priming.
///
/// Constructed at the composition root from the process environment and build
/// flags, then injected so the coordinator stays free of `ProcessInfo` and
/// `#if` reach-ins and tests can drive every priming branch deterministically.
public struct AuthLaunchOptions: Equatable, Sendable {
    /// Whether a UI test requested a cleared auth state (`CMUX_UITEST_CLEAR_AUTH`).
    public let clearAuthRequested: Bool
    /// Whether mock data mode is enabled (priming a fixed mock user).
    public let mockDataEnabled: Bool
    /// The raw process environment used to resolve UI-test fixtures/credentials.
    public let environment: [String: String]
    /// Whether this build includes the `42` debug sign-in shortcut + persisted
    /// debug credentials (DEBUG / `CMUX_DEV_AUTH` builds).
    public let includesDevAuth: Bool

    /// Creates launch options.
    public init(
        clearAuthRequested: Bool,
        mockDataEnabled: Bool,
        environment: [String: String],
        includesDevAuth: Bool
    ) {
        self.clearAuthRequested = clearAuthRequested
        self.mockDataEnabled = mockDataEnabled
        self.environment = environment
        self.includesDevAuth = includesDevAuth
    }

    /// Whether the coordinator should begin auto-login: credentials present and
    /// no tokens already stored.
    public static func shouldStartAutoLogin(
        hasCredentials: Bool,
        hasStoredTokens: Bool
    ) -> Bool {
        hasCredentials && !hasStoredTokens
    }
}
