import Foundation
#if canImport(Security)
import Security
#endif

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
    /// The Stack project this store's slot belongs to. Non-nil keys the
    /// account names per project (`cmux-auth-access-token.<projectID>`), so a
    /// parked session for one backend environment survives while another is
    /// active. `nil` preserves the historical single-slot account names.
    private let projectID: String?
    private let log = AuthDebugLog()

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    /// Creates a Keychain store writing under one exact signed access group.
    ///
    /// - Parameters:
    ///   - service: The bundle-scoped Keychain service.
    ///   - accessGroup: The app's exact signed Keychain access group.
    ///   - legacyProjectID: The Stack project whose older account-only items
    ///     may be adopted from this same access group.
    ///   - projectID: The Stack project keying this store's per-project token
    ///     slot; `nil` keeps the historical single-slot behavior.
    public init(
        service: String,
        accessGroup: String? = nil,
        legacyProjectID: String? = nil,
        projectID: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyProjectID = legacyProjectID
        self.projectID = projectID
    }

    /// The Keychain account name for one token slot. A non-nil `projectID`
    /// suffixes the base account (`<base>.<projectID>`) so each Stack project
    /// gets its own slot inside the bundle-scoped service; `nil` (or empty)
    /// returns the base account unchanged, matching every pre-per-project
    /// install.
    public static func account(base: String, projectID: String?) -> String {
        guard let projectID, !projectID.isEmpty else { return base }
        return "\(base).\(projectID)"
    }

    private var accessTokenAccountName: String {
        Self.account(base: Self.accessTokenAccount, projectID: projectID)
    }

    private var refreshTokenAccountName: String {
        Self.account(base: Self.refreshTokenAccount, projectID: projectID)
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

    public func getStoredAccessToken() async -> String? {
        if let cachedAccessToken { return cachedAccessToken }
        return readOrAdoptLegacyToken(
            account: accessTokenAccountName,
            unsuffixedLegacyAccount: Self.accessTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" }
        )
    }

    public func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return readOrAdoptLegacyToken(
            account: refreshTokenAccountName,
            unsuffixedLegacyAccount: Self.refreshTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" }
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
            allOK = keychainWrite(accessToken, account: accessTokenAccountName) && allOK
        } else {
            keychainDelete(account: accessTokenAccountName)
        }
        if let refreshToken, !refreshToken.isEmpty {
            allOK = keychainWrite(refreshToken, account: refreshTokenAccountName) && allOK
        } else {
            keychainDelete(account: refreshTokenAccountName)
        }
        return allOK
    }

    /// Clears this store's OWN slot plus both legacy tiers it may adopt from
    /// (the un-suffixed single-slot accounts and the old SDK's account-only
    /// items). Another project's suffixed slot is deliberately untouched, so
    /// signing out of one backend environment never destroys a session parked
    /// for the other.
    public func clearTokens() async {
        log.log("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        keychainDelete(account: accessTokenAccountName)
        keychainDelete(account: refreshTokenAccountName)
        deleteUnsuffixedLegacyTokens()
        deleteLegacyTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: readOrAdoptLegacyToken(
                account: accessTokenAccountName,
                unsuffixedLegacyAccount: Self.accessTokenAccount,
                legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" }
            ),
            refreshToken: readOrAdoptLegacyToken(
                account: refreshTokenAccountName,
                unsuffixedLegacyAccount: Self.refreshTokenAccount,
                legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" }
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
            account: refreshTokenAccountName,
            unsuffixedLegacyAccount: Self.refreshTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" }
        )
        let matches = current == compareRefreshToken
        log.log("keychain.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("keychain.compareAndSet: cleared definitively-rejected session")
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

#if canImport(Security)
    private func readOrAdoptLegacyToken(
        account: String,
        unsuffixedLegacyAccount: String,
        legacyAccount: String?
    ) -> String? {
        if let current = keychainRead(account: account) {
            return current
        }
        // Un-suffixed legacy tier: the single-slot account name every install
        // used before per-project slots. It lives in this store's own
        // bundle-scoped service, so no access-group gate is needed (unlike
        // the SDK tier below), and its owner is by construction the
        // last-resolved project — which is exactly this store's project,
        // because an organic project flip clears the store before any read.
        // Adopt it into the suffixed slot and delete the un-suffixed item.
        if account != unsuffixedLegacyAccount,
           let unsuffixed = keychainRead(account: unsuffixedLegacyAccount),
           keychainWrite(unsuffixed, account: account) {
            keychainDelete(account: unsuffixedLegacyAccount)
            return unsuffixed
        }
        // Legacy account-only items are ambiguous without the exact signed
        // access group. Never let a caller using the current-token-only API
        // adopt another installed cmux bundle's Stack session.
        guard accessGroup != nil,
              let legacyAccount,
              let legacy = keychainReadLegacy(account: legacyAccount),
              keychainWrite(legacy, account: account) else {
            return nil
        }
        keychainDeleteLegacy(account: legacyAccount)
        return legacy
    }

    /// Deletes the un-suffixed single-slot legacy items this store may adopt
    /// from. A no-op for a store with no `projectID` (its own slot IS the
    /// un-suffixed account, already deleted by the caller).
    private func deleteUnsuffixedLegacyTokens() {
        guard accessTokenAccountName != Self.accessTokenAccount else { return }
        keychainDelete(account: Self.accessTokenAccount)
        keychainDelete(account: Self.refreshTokenAccount)
    }

    private func deleteLegacyTokens() {
        guard accessGroup != nil, let legacyProjectID else { return }
        keychainDeleteLegacy(account: "stack-auth-access-\(legacyProjectID)")
        keychainDeleteLegacy(account: "stack-auth-refresh-\(legacyProjectID)")
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

    private func keychainRead(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.log("keychain READ status=\(status) account=\(account)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let lookup = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            log.log("keychain UPDATE status=\(updateStatus) account=\(account)")
        }
        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.log("keychain ADD status=\(addStatus) account=\(account)")
            return false
        }
        return true
    }

    private func keychainDelete(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func keychainReadLegacy(account: String) -> String? {
        var query = legacyBaseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                log.log("keychain legacy READ status=\(status) account=\(account)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDeleteLegacy(account: String) {
        _ = SecItemDelete(legacyBaseQuery(account: account) as CFDictionary)
    }
#else
    private func readOrAdoptLegacyToken(
        account: String,
        unsuffixedLegacyAccount: String,
        legacyAccount: String?
    ) -> String? { nil }
    private func deleteUnsuffixedLegacyTokens() {}
    private func deleteLegacyTokens() {}
    private func keychainRead(account: String) -> String? { nil }
    private func keychainWrite(_ value: String, account: String) -> Bool { false }
    private func keychainDelete(account: String) {}
#endif
}
