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
    /// launch (an iOS dev install rebuilt with `--prod-auth`, or back), so the
    /// persisted tokens/user/teams belong to a different project and could
    /// only fail validation or flash the wrong identity.
    ///
    /// Unlike ``clearAuthRequested`` — the UI-test end state, which clears and
    /// stops (suppressing auto-login) — this clear runs BEFORE normal priming
    /// and leaves the rest of launch intact, so DEBUG auto-login credentials
    /// still sign in on the same launch.
    public let clearStaleAuthOnLaunch: Bool

    /// Whether deterministic dev tooling selected an explicit login profile
    /// for this launch. The stored session may belong to a different profile,
    /// so it is cleared before normal priming and the injected credentials are
    /// allowed to sign in during this same launch.
    public let replaceStoredSessionWithAutoLogin: Bool

    /// Whether a build compiled without DEBUG may still sign in from the launch environment's
    /// automatic-login credentials (`CMUX_UITEST_STACK_*`). Only cmux NEXT's PR capture builds set it
    /// (CloudConfiguration.isCaptureBuild: the bench hooks, never shipped, and a `cap<sha10>` tag), so a
    /// capture can drive Release paths signed in to its test account. DEBUG builds always may.
    public let allowsEnvironmentAutoLogin: Bool

    /// Whether this launch signs in from the environment's automatic-login credentials.
    public var environmentAutoLogin: Bool {
        #if DEBUG
        true
        #else
        allowsEnvironmentAutoLogin
        #endif
    }

    /// Whether normal priming must begin from an empty persisted session.
    public var shouldClearStoredSessionBeforePriming: Bool {
        clearStaleAuthOnLaunch || replaceStoredSessionWithAutoLogin
    }

    /// Creates launch options.
    public init(
        clearAuthRequested: Bool,
        mockDataEnabled: Bool,
        environment: [String: String],
        includesDevAuth: Bool,
        clearStaleAuthOnLaunch: Bool = false,
        replaceStoredSessionWithAutoLogin: Bool = false,
        allowsEnvironmentAutoLogin: Bool = false
    ) {
        self.clearAuthRequested = clearAuthRequested
        self.mockDataEnabled = mockDataEnabled
        self.environment = environment
        self.includesDevAuth = includesDevAuth
        self.clearStaleAuthOnLaunch = clearStaleAuthOnLaunch
        self.replaceStoredSessionWithAutoLogin = replaceStoredSessionWithAutoLogin
        self.allowsEnvironmentAutoLogin = allowsEnvironmentAutoLogin
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
