import Foundation

/// The observable session-state snapshot the auth coordinator publishes:
/// whether a user is signed in, who they are, and whether a cached session is
/// still being restored.
public struct CMUXAuthState: Equatable, Sendable {
    /// Whether a user session is currently active.
    public let isAuthenticated: Bool
    /// The signed-in (or cached) user, if any.
    public let currentUser: CMUXAuthUser?
    /// Whether a cached session is being restored/validated at launch.
    public let isRestoringSession: Bool

    /// Creates a state snapshot from its parts.
    public init(isAuthenticated: Bool, currentUser: CMUXAuthUser?, isRestoringSession: Bool) {
        self.isAuthenticated = isAuthenticated
        self.currentUser = currentUser
        self.isRestoringSession = isRestoringSession
    }

    /// The launch-time priming state, decided from the launch inputs in
    /// priority order: cleared auth, mock data, a UI-test fixture user,
    /// pending auto-login, then the cached user. A cached user with known
    /// tokens is treated as signed in immediately while runtime validation
    /// remains explicitly in progress. This lets the authenticated UI render
    /// without allowing token-dependent work to race the restore.
    /// - Parameters:
    ///   - clearAuthRequested: Whether the launch requested a cleared auth state.
    ///   - mockDataEnabled: Whether mock-data mode is active.
    ///   - fixtureUser: A UI-test fixture user, if the launch supplied one.
    ///   - autoLoginCredentials: UI-test auto-login credentials, if supplied.
    ///   - cachedUser: The persisted user from the previous session, if any.
    ///   - hasTokens: Whether the session cache says tokens exist.
    ///   - mockUser: The fixed user mock-data mode presents.
    public static func primed(
        clearAuthRequested: Bool,
        mockDataEnabled: Bool,
        fixtureUser: CMUXAuthUser?,
        autoLoginCredentials: CMUXAuthAutoLoginCredentials?,
        cachedUser: CMUXAuthUser?,
        hasTokens: Bool,
        mockUser: CMUXAuthUser
    ) -> Self {
        if clearAuthRequested {
            return .cleared()
        }

        if mockDataEnabled {
            return Self(isAuthenticated: true, currentUser: mockUser, isRestoringSession: false)
        }

        if let fixtureUser {
            return Self(isAuthenticated: true, currentUser: fixtureUser, isRestoringSession: false)
        }

        if autoLoginCredentials != nil, !hasTokens {
            return Self(isAuthenticated: false, currentUser: cachedUser, isRestoringSession: true)
        }

        if hasTokens, let cachedUser {
            return Self(isAuthenticated: true, currentUser: cachedUser, isRestoringSession: true)
        }

        return Self(isAuthenticated: false, currentUser: cachedUser, isRestoringSession: hasTokens)
    }

    /// The fully signed-out state.
    public static func cleared() -> Self {
        Self(isAuthenticated: false, currentUser: nil, isRestoringSession: false)
    }
}
