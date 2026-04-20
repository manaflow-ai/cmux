import Foundation

public struct CMUXAuthAutoLoginCredentials: Equatable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public enum CMUXAuthLaunchConfig {
    public static func autoLoginCredentials(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> CMUXAuthAutoLoginCredentials? {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard let email = environment["CMUX_UITEST_STACK_EMAIL"], !email.isEmpty else {
            return nil
        }
        guard let password = environment["CMUX_UITEST_STACK_PASSWORD"], !password.isEmpty else {
            return nil
        }
        return CMUXAuthAutoLoginCredentials(email: email, password: password)
    }

    public static func fixtureUser(
        from environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) -> CMUXAuthUser? {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard environment["CMUX_UITEST_AUTH_FIXTURE"] == "1" else {
            return nil
        }
        return CMUXAuthUser(
            id: environment["CMUX_UITEST_AUTH_USER_ID"] ?? "uitest_user",
            primaryEmail: environment["CMUX_UITEST_AUTH_EMAIL"] ?? "uitest@cmux.local",
            displayName: environment["CMUX_UITEST_AUTH_NAME"] ?? "UI Test"
        )
    }
}

public enum CMUXAuthMagicLinkCode {
    public static func compose(code: String, nonce: String) -> String {
        code + nonce
    }
}

public struct CMUXAuthState: Equatable, Sendable {
    public let isAuthenticated: Bool
    public let currentUser: CMUXAuthUser?
    public let isRestoringSession: Bool

    public init(isAuthenticated: Bool, currentUser: CMUXAuthUser?, isRestoringSession: Bool) {
        self.isAuthenticated = isAuthenticated
        self.currentUser = currentUser
        self.isRestoringSession = isRestoringSession
    }

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

        if autoLoginCredentials != nil {
            return Self(isAuthenticated: true, currentUser: cachedUser, isRestoringSession: false)
        }

        return Self(
            isAuthenticated: hasTokens,
            currentUser: cachedUser,
            isRestoringSession: false
        )
    }

    public static func cleared() -> Self {
        Self(isAuthenticated: false, currentUser: nil, isRestoringSession: false)
    }
}
