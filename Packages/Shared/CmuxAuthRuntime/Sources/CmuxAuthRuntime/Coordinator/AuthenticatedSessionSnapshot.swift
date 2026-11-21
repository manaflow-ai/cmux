import Foundation

/// Immutable snapshot of the authenticated session: the account id and both
/// tokens captured together with the session generation they belong to.
///
/// The generation lets a long operation (revoking bindings, say) detect that the
/// session was replaced after the snapshot, so it aborts before acting with one
/// account's identity and another's credentials.
public struct AuthenticatedSessionSnapshot: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// The session generation the account id and tokens were captured under.
    public let generation: UInt64
    /// The signed-in account id (`currentUser.id`) at capture.
    public let accountID: String
    /// The access token for this session.
    public let accessToken: String
    /// The refresh token for this session.
    public let refreshToken: String

    public init(
        generation: UInt64,
        accountID: String,
        accessToken: String,
        refreshToken: String
    ) {
        self.generation = generation
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Redacted: the synthesized reflection would copy live tokens (and the
    /// account id) into logs, assertion output, and crash reports.
    public var description: String {
        "AuthenticatedSessionSnapshot(generation: \(generation), "
            + "accountID: <redacted>, accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Credential-free identity for synchronously binding queued work to the
/// current authenticated session.
public struct AuthenticatedSessionIdentity: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let generation: UInt64
    public let accountID: String

    public init(generation: UInt64, accountID: String) {
        self.generation = generation
        self.accountID = accountID
    }

    public var description: String {
        "AuthenticatedSessionIdentity(generation: \(generation), accountID: <redacted>)"
    }

    public var debugDescription: String { description }
}
