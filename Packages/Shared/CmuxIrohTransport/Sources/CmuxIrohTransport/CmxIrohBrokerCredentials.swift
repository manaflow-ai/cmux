/// One access + refresh credential pair captured from a single session snapshot.
///
/// Assembling a request from one snapshot prevents pairing a stale access token
/// with a freshly-rotated refresh token (or vice versa) when a force refresh
/// lands between two independent token reads.
public struct CmxIrohBrokerCredentials: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// Redacted: the synthesized reflection would copy live bearer/refresh
    /// tokens into logs, assertion output, and crash reports.
    public var description: String {
        "CmxIrohBrokerCredentials(accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}
