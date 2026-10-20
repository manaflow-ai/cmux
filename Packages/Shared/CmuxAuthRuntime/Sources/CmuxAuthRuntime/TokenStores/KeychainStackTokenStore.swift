public import Foundation
#if canImport(Security)
import Security
#endif

/// A privacy-safe description of a Keychain operation that failed.
///
/// This value intentionally excludes account names, service names, and
/// credential data so callers can forward it to diagnostics safely.
public struct KeychainStackTokenStoreFailure: Sendable, Equatable {
    public enum Operation: String, Sendable, Equatable, Hashable {
        case availabilityRead = "availability_read"
        case read
        case legacyRead = "legacy_read"
        case update
        case add
        case delete
        case legacyDelete = "legacy_delete"
    }

    public enum AccountRole: String, Sendable, Equatable, Hashable {
        case access
        case refresh
    }

    public let operation: Operation
    /// Security.framework's `OSStatus`, represented as `Int32` so this value
    /// remains available on platforms without Security.
    public let status: Int32
    public let accountRole: AccountRole
    public let hasAccessGroup: Bool

    public init(
        operation: Operation,
        status: Int32,
        accountRole: AccountRole,
        hasAccessGroup: Bool
    ) {
        self.operation = operation
        self.status = status
        self.accountRole = accountRole
        self.hasAccessGroup = hasAccessGroup
    }
}

/// Data-protection-keychain token store.
///
/// On macOS this is the primary store on Release builds (which carry a
/// keychain-access-groups entitlement). Ad-hoc Debug builds fail keychain
/// writes with `errSecMissingEntitlement`; ``FallbackTokenStore`` detects that
/// and routes to ``FileStackTokenStore`` instead.
///
/// ```swift
/// let store = KeychainStackTokenStore(
///     service: KeychainStackTokenStore.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
/// )
/// ```
public actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    private let service: String
    private let accessGroup: String?
    private let legacyProjectID: String?
    private let log = AuthDebugLog()
    private let onFailure: @Sendable (KeychainStackTokenStoreFailure) -> Void
    private let now: @Sendable () -> Date
    private let failureReportInterval: TimeInterval

    private struct FailureKey: Hashable, Sendable {
        let operation: KeychainStackTokenStoreFailure.Operation
        let status: Int32
        let accountRole: KeychainStackTokenStoreFailure.AccountRole
    }

    /// The last time each failure signature was handed to the diagnostics
    /// callback. Probes can repeat while a build is locked or incorrectly
    /// signed, so this avoids a Sentry log storm.
    private var lastReportedFailures: [FailureKey: Date] = [:]

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    /// Creates a Keychain store writing under one exact signed access group.
    ///
    /// - Parameters:
    ///   - service: The bundle-scoped Keychain service.
    ///   - accessGroup: The app's exact signed Keychain access group.
    ///   - legacyProjectID: The Stack project whose older account-only items
    ///     may be adopted from this same access group.
    ///   - onFailure: Receives privacy-safe diagnostics for unusual Security
    ///     statuses. The default is a no-op.
    ///   - now: Clock used for rate limiting `onFailure`; injectable for tests.
    ///   - failureReportInterval: Minimum interval for forwarding one
    ///     operation/status/account-role signature.
    public init(
        service: String,
        accessGroup: String? = nil,
        legacyProjectID: String? = nil,
        onFailure: @escaping @Sendable (KeychainStackTokenStoreFailure) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init,
        failureReportInterval: TimeInterval = 300
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyProjectID = legacyProjectID
        self.onFailure = onFailure
        self.now = now
        self.failureReportInterval = max(0, failureReportInterval)
    }

    /// The keychain service name auth tokens are stored under, namespaced by
    /// bundle id so tagged dev builds don't clobber the stable app's session.
    /// - Parameter bundleIdentifier: The app's bundle identifier (the caller
    ///   reads `Bundle.main`; this type never does).
    public static func serviceName(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return "com.cmuxterm.app.auth"
        }
        return "\(bundleIdentifier).auth"
    }

    /// Returns the exact Keychain access group granted to this signed process
    /// for `bundleIdentifier`.
    ///
    /// macOS release artifacts are signed after Xcode builds the app, so the
    /// access-group value cannot safely be inferred from an Xcode build
    /// setting. Reading the signed entitlement also keeps Nightly/RC/stable
    /// bundle identities isolated from one another. Unsigned Debug builds do
    /// not have this entitlement and intentionally return `nil`, allowing the
    /// file fallback to handle them.
    public static func signedAccessGroup(bundleIdentifier: String?) -> String? {
#if os(macOS) && canImport(Security)
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let task = SecTaskCreateFromSelf(nil),
              let rawGroups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String] else {
            return nil
        }
        return accessGroup(from: rawGroups, bundleIdentifier: bundleIdentifier)
#else
        return nil
#endif
    }

    /// Selects the signed group whose bundle suffix exactly matches the app.
    /// Kept pure so build-channel isolation can be tested without changing the
    /// process signature in a unit test.
    public static func accessGroup(
        from groups: [String],
        bundleIdentifier: String?
    ) -> String? {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !bundleIdentifier.isEmpty else {
            return nil
        }
        let suffix = ".\(bundleIdentifier)"
        return groups.first { group in
            group.hasSuffix(suffix)
        }
    }

    /// Reports whether the app can currently query both auth-keychain items.
    ///
    /// Security collapses several query failures into `nil` in the token read
    /// API. This probe preserves the distinction between an empty, readable
    /// keychain (`errSecItemNotFound`) and a keychain that is unavailable due
    /// to protection, access, or signing state.
    public func isStorageAvailable() async -> Bool {
#if canImport(Security)
        let statuses = [
            keychainReadStatus(
                account: Self.accessTokenAccount,
                accountRole: .access
            ),
            keychainReadStatus(
                account: Self.refreshTokenAccount,
                accountRole: .refresh
            ),
        ]
        let available = statuses.allSatisfy {
            $0 == errSecSuccess || $0 == errSecItemNotFound
        }
        if !available {
            log.log("keychain availability unavailable statuses=\(statuses)")
        }
        return available
#else
        return false
#endif
    }

    public func getStoredAccessToken() async -> String? {
        if let cachedAccessToken { return cachedAccessToken }
        return readOrAdoptLegacyToken(
            account: Self.accessTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" },
            accountRole: .access
        )
    }

    public func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return readOrAdoptLegacyToken(
            account: Self.refreshTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" },
            accountRole: .refresh
        )
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        _ = await trySetTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Same as `setTokens` but returns whether every keychain operation
    /// actually succeeded. Used by ``FallbackTokenStore`` to decide when to
    /// give up on Keychain and route to the file store.
    public func trySetTokens(accessToken: String?, refreshToken: String?) async -> Bool {
        log.log("keychain.setTokens: hasAccess=\(accessToken?.isEmpty == false) hasRefresh=\(refreshToken?.isEmpty == false)")
        cachedAccessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        cachedRefreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil

        var allOK = true
        if let accessToken, !accessToken.isEmpty {
            allOK = keychainWrite(
                accessToken,
                account: Self.accessTokenAccount,
                accountRole: .access
            ) && allOK
        } else {
            keychainDelete(account: Self.accessTokenAccount, accountRole: .access)
        }
        if let refreshToken, !refreshToken.isEmpty {
            allOK = keychainWrite(
                refreshToken,
                account: Self.refreshTokenAccount,
                accountRole: .refresh
            ) && allOK
        } else {
            keychainDelete(account: Self.refreshTokenAccount, accountRole: .refresh)
        }
        return allOK
    }

    public func clearTokens() async {
        log.log("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        keychainDelete(account: Self.accessTokenAccount, accountRole: .access)
        keychainDelete(account: Self.refreshTokenAccount, accountRole: .refresh)
        deleteLegacyTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: readOrAdoptLegacyToken(
                account: Self.accessTokenAccount,
                legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" },
                accountRole: .access
            ),
            refreshToken: readOrAdoptLegacyToken(
                account: Self.refreshTokenAccount,
                legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" },
                accountRole: .refresh
            )
        )
        guard snapshot.matches(expectedAccessToken: accessToken, expectedRefreshToken: refreshToken) else {
            log.log("keychain.clearTokensIfCurrent: skipped stale clear")
            return false
        }
        log.log("keychain.clearTokensIfCurrent: cleared matching tokens")
        await clearTokens()
        return true
    }

    /// Replaces tokens only while the stored refresh token is still `compareRefreshToken`.
    ///
    /// The compare value is the staleness guard. A double-nil replacement is the
    /// Stack SDK's `RefreshOutcome.definitivelyRejected` clear, and must delete
    /// the persisted session once the current refresh token still matches.
    public func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = readOrAdoptLegacyToken(
            account: Self.refreshTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" },
            accountRole: .refresh
        )
        let matches = current == compareRefreshToken
        log.log("keychain.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false) \(AccessTokenLifetime.logFields(newAccessToken))")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("keychain.compareAndSet: cleared definitively-rejected session")
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

#if canImport(Security)
    private func readOrAdoptLegacyToken(
        account: String,
        legacyAccount: String?,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> String? {
        if let current = keychainRead(account: account, accountRole: accountRole) {
            return current
        }
        // Legacy account-only items are ambiguous without the exact signed
        // access group. Never let a caller using the current-token-only API
        // adopt another installed cmux bundle's Stack session.
        guard accessGroup != nil,
              let legacyAccount,
              let legacy = keychainReadLegacy(account: legacyAccount, accountRole: accountRole),
              keychainWrite(legacy, account: account, accountRole: accountRole) else {
            return nil
        }
        keychainDeleteLegacy(account: legacyAccount, accountRole: accountRole)
        return legacy
    }

    private func deleteLegacyTokens() {
        guard accessGroup != nil, let legacyProjectID else { return }
        keychainDeleteLegacy(
            account: "stack-auth-access-\(legacyProjectID)",
            accountRole: .access
        )
        keychainDeleteLegacy(
            account: "stack-auth-refresh-\(legacyProjectID)",
            accountRole: .refresh
        )
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func legacyBaseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            // The legacy Stack SDK omitted this attribute when adding items,
            // which Keychain persists as the empty service. An omitted query
            // attribute is a wildcard and could match another credential.
            kSecAttrService as String: "",
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func keychainRead(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.log("keychain READ status=\(status) account=\(account)")
                reportFailure(
                    operation: .read,
                    status: status,
                    accountRole: accountRole
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainReadStatus(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> OSStatus {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            reportFailure(
                operation: .availabilityRead,
                status: status,
                accountRole: accountRole
            )
        }
        return status
    }

    private func keychainWrite(
        _ value: String,
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let lookup = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            log.log("keychain UPDATE status=\(updateStatus) account=\(account)")
            reportFailure(
                operation: .update,
                status: updateStatus,
                accountRole: accountRole
            )
        }
        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.log("keychain ADD status=\(addStatus) account=\(account)")
            reportFailure(
                operation: .add,
                status: addStatus,
                accountRole: accountRole
            )
            return false
        }
        return true
    }

    private func keychainDelete(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        reportFailure(
            operation: .delete,
            status: status,
            accountRole: accountRole
        )
    }

    private func keychainReadLegacy(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> String? {
        var query = legacyBaseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.log("keychain legacy READ status=\(status) account=\(account)")
                reportFailure(
                    operation: .legacyRead,
                    status: status,
                    accountRole: accountRole
                )
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDeleteLegacy(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) {
        let status = SecItemDelete(legacyBaseQuery(account: account) as CFDictionary)
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        reportFailure(
            operation: .legacyDelete,
            status: status,
            accountRole: accountRole
        )
    }
#else
    private func readOrAdoptLegacyToken(
        account: String,
        legacyAccount: String?,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> String? { nil }
    private func deleteLegacyTokens() {}
    private func keychainRead(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> String? { nil }
    private func keychainWrite(
        _ value: String,
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) -> Bool { false }
    private func keychainDelete(
        account: String,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) {}
#endif

    private func reportFailure(
        operation: KeychainStackTokenStoreFailure.Operation,
        status: Int32,
        accountRole: KeychainStackTokenStoreFailure.AccountRole
    ) {
        let key = FailureKey(
            operation: operation,
            status: status,
            accountRole: accountRole
        )
        let timestamp = now()
        if let last = lastReportedFailures[key],
           timestamp.timeIntervalSince(last) < failureReportInterval {
            return
        }
        lastReportedFailures[key] = timestamp
        onFailure(
            KeychainStackTokenStoreFailure(
                operation: operation,
                status: status,
                accountRole: accountRole,
                hasAccessGroup: accessGroup != nil
            )
        )
    }
}
