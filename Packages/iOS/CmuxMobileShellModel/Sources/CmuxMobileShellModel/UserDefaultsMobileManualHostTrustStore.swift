import Foundation

/// UserDefaults-backed manual-host trust store for production.
public actor UserDefaultsMobileManualHostTrustStore: MobileManualHostTrustStoring {
    private let defaults: UserDefaults
    private let key: String

    /// Creates a durable manual-host trust store.
    /// - Parameters:
    ///   - defaults: The backing defaults store.
    ///   - key: The defaults key that stores approved scopes.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.manualHostTrust.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Creates a durable manual-host trust store in a named defaults suite.
    /// - Parameters:
    ///   - suiteName: The `UserDefaults` suite name.
    ///   - key: The defaults key that stores approved scopes.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.manualHostTrust.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    /// Returns whether the given host/port/account scope is already trusted.
    /// - Parameter scope: The scope to look up.
    public func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        Set(defaults.stringArray(forKey: key) ?? []).contains(scope.storageKey)
    }

    /// Persists trust for exactly the given host/port/account scope.
    /// - Parameter scope: The scope to approve.
    public func trust(_ scope: MobileManualHostTrustScope) async {
        var trusted = Set(defaults.stringArray(forKey: key) ?? [])
        trusted.insert(scope.storageKey)
        defaults.set(trusted.sorted(), forKey: key)
    }

    /// Removes every stored approval.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }
}
