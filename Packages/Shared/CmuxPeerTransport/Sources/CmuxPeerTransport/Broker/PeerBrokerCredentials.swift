/// One access + refresh credential pair captured from a single session snapshot.
///
/// Assembling a request from one snapshot prevents pairing a stale access
/// token with a freshly-rotated refresh token (or vice versa) when a force
/// refresh lands between two independent token reads.
public struct PeerBrokerCredentials: Sendable, Equatable, CustomStringConvertible,
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
        "PeerBrokerCredentials(accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Supplies the short-lived account credentials the trust broker requires.
///
/// `capture` returns BOTH tokens from ONE atomic snapshot and distinguishes
/// two failure states at the auth boundary:
///
/// - Returning `nil` means the credentials are DEFINITIVELY absent (signed
///   out, account switched). The broker client fails closed with
///   ``PeerBrokerError/unauthorized``.
/// - Throwing means the source could not read a coherent pair RIGHT NOW (the
///   token store is owned by a launch/foreground revalidation, or a re-mint
///   is in flight or offline). The client classifies that as
///   ``PeerBrokerError/connectivity`` so retries and cached-grant fallbacks
///   apply instead of tearing trusted state down.
///
/// `forceRefresh` asks the platform auth owner to mint a replacement session.
/// The client calls it at most once per request, and only inside the one-shot
/// 401 recovery when a re-captured pair still carries the rejected access
/// token. Account pinning (rejecting a snapshot for another account with
/// `nil`) is the provider's responsibility.
public struct PeerBrokerTokenProvider: Sendable {
    public let capture: @Sendable () async throws -> PeerBrokerCredentials?
    public let forceRefresh: @Sendable () async throws -> Void

    public init(
        capture: @escaping @Sendable () async throws -> PeerBrokerCredentials?,
        forceRefresh: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.capture = capture
        self.forceRefresh = forceRefresh
    }
}
