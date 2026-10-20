import Foundation

/// Email/password credentials a UI-test launch supplies for automatic
/// sign-in.
public struct CMUXAuthAutoLoginCredentials: Equatable, Sendable {
    /// The account email.
    public let email: String
    /// The account password.
    public let password: String

    /// Creates credentials from their parts.
    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }

    /// Parse auto-login credentials from the launch environment
    /// (`CMUX_UITEST_STACK_EMAIL` / `CMUX_UITEST_STACK_PASSWORD`), or `nil`
    /// when they are absent. A cleared-auth or mock-data launch always wins
    /// over auto-login.
    /// - Parameters:
    ///   - environment: The process launch environment.
    ///   - clearAuth: Whether the launch requested a cleared auth state.
    ///   - mockDataEnabled: Whether mock-data mode is active.
    public init?(
        environment: [String: String],
        clearAuth: Bool,
        mockDataEnabled: Bool
    ) {
        if clearAuth || mockDataEnabled {
            return nil
        }
        guard let email = environment["CMUX_UITEST_STACK_EMAIL"], !email.isEmpty else {
            return nil
        }
        guard let password = environment["CMUX_UITEST_STACK_PASSWORD"], !password.isEmpty else {
            return nil
        }
        self.init(email: email, password: password)
    }
}
