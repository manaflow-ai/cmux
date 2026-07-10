public import Foundation
import OSLog

nonisolated private let manualHostTrustStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "ManualHostTrust")

/// UserDefaults-backed manual-host trust store for production.
public actor UserDefaultsMobileManualHostTrustStore: MobileManualHostTrustStoring {
    /// Default lifetime for a same-app-session manual-host approval.
    public static let defaultTrustDuration: TimeInterval = 10 * 60

    private let defaults: UserDefaults
    private let key: String
    private let sessionIdentifier: String
    private let trustDuration: TimeInterval
    private let now: @Sendable () -> Date
    private var persistedExpirations: [String: TimeInterval]
    private var trustedScopes: [MobileManualHostTrustScope: TimeInterval]

    /// Creates a same-session manual-host trust store.
    /// - Parameters:
    ///   - defaults: The backing defaults store.
    ///   - key: The defaults key that stores approved scopes and their expiry times.
    ///   - sessionIdentifier: The app-session boundary for approvals.
    ///   - trustDuration: How long a host approval remains valid within this session.
    ///   - now: Clock source used to evaluate expiry.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.manualHostTrust.v2",
        sessionIdentifier: String = UUID().uuidString,
        trustDuration: TimeInterval = UserDefaultsMobileManualHostTrustStore.defaultTrustDuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.sessionIdentifier = sessionIdentifier
        self.trustDuration = trustDuration
        self.now = now
        let storedState = MobileManualHostTrustStoredState(
            defaults: defaults,
            key: key,
            sessionIdentifier: sessionIdentifier
        )
        self.persistedExpirations = storedState.persistedExpirations
        self.trustedScopes = storedState.trustedScopes
    }

    /// Creates a same-session manual-host trust store in a named defaults suite.
    /// - Parameters:
    ///   - suiteName: The `UserDefaults` suite name.
    ///   - key: The defaults key that stores approved scopes and their expiry times.
    ///   - sessionIdentifier: The app-session boundary for approvals.
    ///   - trustDuration: How long a host approval remains valid within this session.
    ///   - now: Clock source used to evaluate expiry.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.manualHostTrust.v2",
        sessionIdentifier: String = UUID().uuidString,
        trustDuration: TimeInterval = UserDefaultsMobileManualHostTrustStore.defaultTrustDuration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let resolvedDefaults: UserDefaults
        if let suiteDefaults = UserDefaults(suiteName: suiteName) {
            resolvedDefaults = suiteDefaults
        } else {
            assertionFailure("Failed to resolve UserDefaults suite \(suiteName); falling back to .standard")
            manualHostTrustStoreLog.error(
                "failed to resolve UserDefaults suite \(suiteName, privacy: .public); falling back to standard defaults"
            )
            resolvedDefaults = .standard
        }
        self.defaults = resolvedDefaults
        self.key = key
        self.sessionIdentifier = sessionIdentifier
        self.trustDuration = trustDuration
        self.now = now
        let storedState = MobileManualHostTrustStoredState(
            defaults: resolvedDefaults,
            key: key,
            sessionIdentifier: sessionIdentifier
        )
        self.persistedExpirations = storedState.persistedExpirations
        self.trustedScopes = storedState.trustedScopes
    }

    /// Returns whether the given host/port/account scope is already trusted and unexpired.
    /// - Parameter scope: The scope to look up.
    public func isTrusted(_ scope: MobileManualHostTrustScope) async -> Bool {
        guard let expiresAt = trustedScopes[scope] else {
            return false
        }
        guard expiresAt > now().timeIntervalSince1970 else {
            trustedScopes.removeValue(forKey: scope)
            persistedExpirations.removeValue(forKey: sessionStorageKey(for: scope))
            defaults.set(persistedExpirations, forKey: key)
            return false
        }
        return true
    }

    /// Persists trust for exactly the given host/port/account scope until its expiry time.
    /// - Parameter scope: The scope to approve.
    public func trust(_ scope: MobileManualHostTrustScope) async {
        guard !Task.isCancelled else { return }
        let currentTime = now().timeIntervalSince1970
        persistedExpirations = persistedExpirations.filter { _, expiresAt in
            expiresAt > currentTime
        }
        trustedScopes = trustedScopes.filter { _, expiresAt in
            expiresAt > currentTime
        }
        let expiresAt = currentTime + trustDuration
        trustedScopes[scope] = expiresAt
        persistedExpirations[sessionStorageKey(for: scope)] = expiresAt
        defaults.set(persistedExpirations, forKey: key)
    }

    /// Returns the recorded absolute expiry so the connection owner can queue
    /// reapproval even when no further RPC happens after the deadline.
    public func expirationDate(for scope: MobileManualHostTrustScope) async -> Date? {
        trustedScopes[scope].map(Date.init(timeIntervalSince1970:))
    }

    /// Removes every stored approval.
    public func removeAll() async {
        persistedExpirations.removeAll()
        trustedScopes.removeAll()
        defaults.removeObject(forKey: key)
    }

    private func sessionStorageKey(for scope: MobileManualHostTrustScope) -> String {
        [
            sessionIdentifier.mobileManualHostTrustStorageEscaped,
            scope.storageKey,
        ].joined(separator: "|")
    }
}
