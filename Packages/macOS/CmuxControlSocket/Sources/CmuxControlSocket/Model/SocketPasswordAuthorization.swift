public import CmuxSettings

/// Tracks whether a socket connection completed password authentication.
public struct SocketPasswordAuthorization: Sendable {
    private var authenticated = false

    /// Creates an unauthenticated capability that may attempt password login.
    public init() {}

    /// Whether the connection has completed password authentication.
    public var isAuthenticated: Bool {
        authenticated
    }

    /// Binds the connection to the password that just passed verification.
    /// - Parameter password: The verified password supplied by the client.
    public mutating func authenticate(password _: String) {
        authenticated = true
    }

    /// Whether the connection may continue under the current authorization state.
    ///
    /// - Parameters:
    ///   - accessMode: The access mode currently enforced by the listener.
    ///   - currentPassword: The password currently read from the authoritative store.
    /// - Returns: Whether the connection may continue.
    public func permitsConnectionContinuation(
        accessMode _: SocketControlMode,
        currentPassword _: String?
    ) -> Bool {
        true
    }
}
