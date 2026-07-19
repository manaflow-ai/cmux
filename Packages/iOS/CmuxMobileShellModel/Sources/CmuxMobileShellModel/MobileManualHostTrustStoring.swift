public import Foundation

/// Persistence for explicit manual-host approvals.
public protocol MobileManualHostTrustStoring: Sendable {
    /// Returns whether the given host/port/account scope is already trusted.
    /// - Parameter scope: The scope to look up.
    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool

    /// Persists trust for exactly the given host/port/account scope.
    /// - Parameter scope: The scope to approve.
    func trust(_ scope: MobileManualHostTrustScope) async

    /// Returns when the approval expires, or `nil` for stores without expiry.
    /// - Parameter scope: The approved scope to inspect.
    func expirationDate(for scope: MobileManualHostTrustScope) async -> Date?

    /// Removes every stored approval.
    func removeAll() async
}

/// Default behavior for trust stores that do not expire approvals themselves.
public extension MobileManualHostTrustStoring {
    /// Returns no expiry when the store does not own an expiration policy.
    /// - Parameter scope: The approved scope to inspect.
    func expirationDate(for scope: MobileManualHostTrustScope) async -> Date? {
        _ = scope
        return nil
    }
}
