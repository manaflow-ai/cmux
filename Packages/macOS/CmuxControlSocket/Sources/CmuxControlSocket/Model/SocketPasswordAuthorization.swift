public import CmuxSettings
internal import CryptoKit
internal import Foundation

/// Tracks the credential revision proved by a socket connection.
public struct SocketPasswordAuthorization: Sendable {
    private var credentialFingerprint: Data?
    private var nextCredentialRefreshUptimeNanoseconds: UInt64 = 0

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
        nextCredentialRefreshUptimeNanoseconds = 0
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

    /// Checks the current credential no more frequently than a caller-defined interval.
    ///
    /// This keeps high-volume connection consumers on an in-memory fast path while
    /// still detecting password files replaced outside cmux at a bounded cadence.
    ///
    /// - Parameters:
    ///   - accessMode: The access mode currently enforced by the listener.
    ///   - monotonicNowNanoseconds: Current monotonic uptime in nanoseconds.
    ///   - minimumCredentialRefreshIntervalNanoseconds: Minimum interval between
    ///     reads from `currentPassword` for an authenticated password connection.
    ///   - currentPassword: Lazily reads the password from the authoritative store.
    /// - Returns: Whether the connection may continue.
    public mutating func permitsConnectionContinuation(
        accessMode: SocketControlMode,
        monotonicNowNanoseconds: UInt64,
        minimumCredentialRefreshIntervalNanoseconds: UInt64,
        currentPassword: () -> String?
    ) -> Bool {
        guard accessMode.requiresPasswordAuth, credentialFingerprint != nil else {
            return permitsConnectionContinuation(accessMode: accessMode, currentPassword: nil)
        }
        guard monotonicNowNanoseconds >= nextCredentialRefreshUptimeNanoseconds else {
            return true
        }
        let (nextRefresh, overflowed) = monotonicNowNanoseconds.addingReportingOverflow(
            minimumCredentialRefreshIntervalNanoseconds
        )
        nextCredentialRefreshUptimeNanoseconds = overflowed ? .max : nextRefresh
        return permitsConnectionContinuation(
            accessMode: accessMode,
            currentPassword: currentPassword()
        )
    }

    private func fingerprint(_ password: String) -> Data {
        Data(SHA256.hash(data: Data(password.utf8)))
    }
}
