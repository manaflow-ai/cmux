public import Foundation

/// Persisted pair grant for one acceptor endpoint.
public struct IrxGrantSnapshot: Codable, Equatable, Sendable {
    public var acceptorBindingID: String
    public var grantJWS: String
    public var expiresAt: Date

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
