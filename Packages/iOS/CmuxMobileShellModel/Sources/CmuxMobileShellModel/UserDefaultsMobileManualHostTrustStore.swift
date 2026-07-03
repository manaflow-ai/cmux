import Foundation
import OSLog

nonisolated private let manualHostTrustStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "ManualHostTrust")

/// UserDefaults-backed manual-host trust store for production.
public actor UserDefaultsMobileManualHostTrustStore: MobileManualHostTrustStoring {
    /// Default lifetime for a manual-host approval.
    public static let defaultTrustDuration: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String
    private let trustDuration: TimeInterval
    private let now: @Sendable () -> Date

    /// Creates a durable manual-host trust store.
    /// - Parameters:
    ///   - defaults: The backing defaults store.
    ///   - key: The defaults key that stores approved scopes and their expiry times.
    ///   - trustDuration: How long a host approval remains valid.
    ///   - now: Clock source used to evaluate expiry.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.manualHostTrust.v2",
        trustDuration: TimeInterval = Self.defaultTrustDuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.trustDuration = trustDuration
        self.now = now
    }

    /// Creates a durable manual-host trust store in a named defaults suite.
    /// - Parameters:
    ///   - suiteName: The `UserDefaults` suite name.
    ///   - key: The defaults key that stores approved scopes and their expiry times.
    ///   - trustDuration: How long a host approval remains valid.
    ///   - now: Clock source used to evaluate expiry.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.manualHostTrust.v2",
        trustDuration: TimeInterval = Self.defaultTrustDuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let suiteDefaults = UserDefaults(suiteName: suiteName) {
            self.defaults = suiteDefaults
        } else {
            assertionFailure("Failed to resolve UserDefaults suite \(suiteName); falling back to .standard")
            manualHostTrustStoreLog.error(
                "failed to resolve UserDefaults suite \(suiteName, privacy: .public); falling back to standard defaults"
            )
            self.defaults = .standard
        }
        self.key = key
        self.trustDuration = trustDuration
        self.now = now
    }

    /// Returns whether the given host/port/account scope is already trusted and unexpired.
    /// - Parameter scope: The scope to look up.
    public func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        var trusted = trustedExpirations()
        guard let expiresAt = trusted[scope.storageKey] else {
            return false
        }
        guard expiresAt > now().timeIntervalSince1970 else {
            trusted.removeValue(forKey: scope.storageKey)
            defaults.set(trusted, forKey: key)
            return false
        }
        return true
    }

    /// Persists trust for exactly the given host/port/account scope until its expiry time.
    /// - Parameter scope: The scope to approve.
    public func trust(_ scope: MobileManualHostTrustScope) async {
        let currentTime = now().timeIntervalSince1970
        var trusted = trustedExpirations().filter { _, expiresAt in
            expiresAt > currentTime
        }
        trusted[scope.storageKey] = currentTime + trustDuration
        defaults.set(trusted, forKey: key)
    }

    /// Removes every stored approval.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }

    private func trustedExpirations() -> [String: TimeInterval] {
        guard let raw = defaults.dictionary(forKey: key) else {
            return [:]
        }
        var trusted: [String: TimeInterval] = [:]
        for (scope, expiresAt) in raw {
            if let expiresAt = expiresAt as? TimeInterval {
                trusted[scope] = expiresAt
            } else if let expiresAt = expiresAt as? NSNumber {
                trusted[scope] = expiresAt.doubleValue
            }
        }
        return trusted
    }
}
