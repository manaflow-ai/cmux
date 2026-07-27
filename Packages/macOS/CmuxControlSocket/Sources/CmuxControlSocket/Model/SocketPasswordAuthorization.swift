public import CmuxSettings
internal import CryptoKit
internal import Foundation

/// Tracks the credential revision proved by a socket connection.
public struct SocketPasswordAuthorization: Sendable {
    private var credentialFingerprint: Data?

    var authenticatedCredentialFingerprint: Data? {
        credentialFingerprint
    }

    /// Creates an unauthenticated capability that may attempt password login.
    public init() {}

    /// Whether the connection has completed password authentication.
    public var isAuthenticated: Bool {
        credentialFingerprint != nil
    }

    /// Binds the connection to the password that just passed verification.
    /// - Parameter password: The verified password supplied by the client.
    public mutating func authenticate(password: String) {
        credentialFingerprint = fingerprint(password)
    }

    /// Whether the connection may continue under the current authorization state.
    ///
    /// - Parameters:
    ///   - accessMode: The access mode currently enforced by the listener.
    ///   - currentPassword: The password currently read from the authoritative store.
    /// - Returns: Whether the connection may continue.
    public func permitsConnectionContinuation(
        accessMode: SocketControlMode,
        currentPassword: String?
    ) -> Bool {
        guard accessMode.requiresPasswordAuth else { return true }
        guard let credentialFingerprint else {
            // An unauthenticated client must remain connected long enough to
            // attempt auth.login and receive a useful failure response.
            return true
        }
        guard let currentPassword else { return false }
        return credentialFingerprint == fingerprint(currentPassword)
    }

    private func fingerprint(_ password: String) -> Data {
        Data(SHA256.hash(data: Data(password.utf8)))
    }
}
