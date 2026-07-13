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

    /// Whether launch must first drop the previous auth environment's local
    /// state: the install's resolved Stack project changed since its last
    /// launch (an iOS dev install rebuilt for production auth, or back), so
    /// the persisted tokens/user/teams belong to a different project and could
    /// only fail validation or flash the wrong identity.
    ///
    /// Unlike ``clearAuthRequested`` — the UI-test end state, which clears and
    /// stops (suppressing auto-login) — this clear runs BEFORE normal priming
    /// and leaves the rest of launch intact, so DEBUG auto-login credentials
    /// still sign in on the same launch.
    public let clearStaleAuthOnLaunch: Bool

    /// Creates launch options.
    public init(
        clearAuthRequested: Bool,
        mockDataEnabled: Bool,
        environment: [String: String],
        includesDevAuth: Bool,
        clearStaleAuthOnLaunch: Bool = false
    ) {
        self.clearAuthRequested = clearAuthRequested
        self.mockDataEnabled = mockDataEnabled
        self.environment = environment
        self.includesDevAuth = includesDevAuth
        self.clearStaleAuthOnLaunch = clearStaleAuthOnLaunch
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
