/// An immutable refresh token pinned to one authenticated account and session
/// generation. Its textual representations redact identity and credentials.
public struct AuthenticatedRefreshTokenSnapshot:
    Sendable,
    Equatable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The session generation under which the credential was captured.
    public let generation: UInt64

    /// The signed-in account identifier at capture time.
    public let accountID: String

    /// The refresh token for the captured session.
    public let refreshToken: String

    /// Creates a refresh-token snapshot for one authenticated session.
    public init(
        generation: UInt64,
        accountID: String,
        refreshToken: String
    ) {
        self.generation = generation
        self.accountID = accountID
        self.refreshToken = refreshToken
    }

    /// A redacted description safe for logs and assertions.
    public var description: String {
        "AuthenticatedRefreshTokenSnapshot("
            + "generation: \(generation), "
            + "accountID: <redacted>, "
            + "refreshToken: <redacted>)"
    }

    /// A redacted debug description safe for crash reports.
    public var debugDescription: String { description }
}
