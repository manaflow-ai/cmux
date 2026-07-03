import Foundation

/// Volatile manual-host trust store whose approvals last only for this actor's lifetime.
public actor InMemoryMobileManualHostTrustStore: MobileManualHostTrustStoring {
    private var trustedScopes: Set<MobileManualHostTrustScope> = []

    /// Creates an empty in-memory trust store.
    public init() {}

    /// Returns whether the given host/port/account scope is already trusted.
    /// - Parameter scope: The scope to look up.
    public func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        trustedScopes.contains(scope)
    }

    /// Persists trust for exactly the given host/port/account scope.
    /// - Parameter scope: The scope to approve.
    public func trust(_ scope: MobileManualHostTrustScope) async {
        trustedScopes.insert(scope)
    }

    /// Removes every stored approval.
    public func removeAll() async {
        trustedScopes.removeAll()
    }
}
