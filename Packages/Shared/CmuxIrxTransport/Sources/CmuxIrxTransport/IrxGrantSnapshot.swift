public import Foundation

/// Persisted pair grant for one acceptor endpoint.
public struct IrxGrantSnapshot: Codable, Equatable, Sendable {
    /// The binding identifier of the acceptor endpoint.
    public var acceptorBindingID: String
    /// The signed pair grant returned by the broker.
    public var grantJWS: String
    /// The grant's expiration time.
    public var expiresAt: Date

    /// Creates a persisted pair-grant receipt.
    public init(acceptorBindingID: String, grantJWS: String, expiresAt: Date) {
        self.acceptorBindingID = acceptorBindingID
        self.grantJWS = grantJWS
        self.expiresAt = expiresAt
    }

    /// Grants live seven days; retain a day of renewal margin.
    public func isFresh(at now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) > 24 * 3600
    }
}
