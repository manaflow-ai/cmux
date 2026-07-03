import Foundation

/// Persistence for explicit manual-host approvals.
public protocol MobileManualHostTrustStoring: Sendable {
    /// Returns whether the given host/port/account scope is already trusted.
    /// - Parameter scope: The scope to look up.
    func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool

    /// Persists trust for exactly the given host/port/account scope.
    /// - Parameter scope: The scope to approve.
    func trust(_ scope: MobileManualHostTrustScope) async

    /// Removes every stored approval.
    func removeAll() async
}
