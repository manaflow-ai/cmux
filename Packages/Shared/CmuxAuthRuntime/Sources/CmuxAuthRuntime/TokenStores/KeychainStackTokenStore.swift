import Foundation

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
    #if canImport(Security)
    static let keychainAccessibility = SecItemKeychain.accessibility
    #endif
    private let service: String
    private let accessGroup: String?
    private let legacyProjectID: String?
    private let keychain: any KeychainItemStoring
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
    public init(
        service: String,
        accessGroup: String? = nil,
        legacyProjectID: String? = nil
    ) {
        #if canImport(Security)
        let keychain: any KeychainItemStoring = SecItemKeychain()
        #else
        let keychain: any KeychainItemStoring = UnavailableKeychain()
        #endif
        self.init(service: service, accessGroup: accessGroup, legacyProjectID: legacyProjectID, keychain: keychain)
    }

    /// Creates a store over the given Keychain (tests pass an in-memory one).
    init(
        service: String,
        accessGroup: String?,
        legacyProjectID: String?,
        keychain: any KeychainItemStoring
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.legacyProjectID = legacyProjectID
        self.keychain = keychain
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
            account: Self.accessTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" }
        )
    }

    public func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return readOrAdoptLegacyToken(
            account: Self.refreshTokenAccount,
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
            allOK = keychainWrite(accessToken, account: Self.accessTokenAccount) && allOK
        } else {
            keychainDelete(account: Self.accessTokenAccount)
        }
        if let refreshToken, !refreshToken.isEmpty {
            allOK = keychainWrite(refreshToken, account: Self.refreshTokenAccount) && allOK
        } else {
            keychainDelete(account: Self.refreshTokenAccount)
        }
        return allOK
    }

    public func clearTokens() async {
        log.log("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        if !hardenTokensBeforeClear() {
            log.log("clearTokens continuing after one or more accessibility preflights failed")
        }
        keychainDelete(account: Self.accessTokenAccount)
        keychainDelete(account: Self.refreshTokenAccount)
        deleteLegacyTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: readOrAdoptLegacyToken(
                account: Self.accessTokenAccount,
                legacyAccount: legacyProjectID.map { "stack-auth-access-\($0)" }
            ),
            refreshToken: readOrAdoptLegacyToken(
                account: Self.refreshTokenAccount,
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
            account: Self.refreshTokenAccount,
            legacyAccount: legacyProjectID.map { "stack-auth-refresh-\($0)" }
        )
        let matches = current == compareRefreshToken
        log.log("keychain.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false) \(AccessTokenLifetime.logFields(newAccessToken))")
        guard matches else { return }
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("keychain.compareAndSet: cleared definitively-rejected session")
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    private func readOrAdoptLegacyToken(
        account: String,
        legacyAccount: String?
    ) -> String? {
        if let current = keychainRead(account: account) {
            if accessGroup != nil,
               let legacyAccount,
               !hardenLegacyTokenIfPresent(account: legacyAccount, deleteAfterHardening: true) {
                return nil
            }
            return current
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
        _ = keychainDeleteLegacy(account: legacyAccount)
        return legacy
    }

    private func deleteLegacyTokens() {
        guard accessGroup != nil, let legacyProjectID else { return }
        _ = keychainDeleteLegacy(account: "stack-auth-access-\(legacyProjectID)")
        _ = keychainDeleteLegacy(account: "stack-auth-refresh-\(legacyProjectID)")
    }

    private func hardenTokensBeforeClear() -> Bool {
        var allOK = true
        allOK = hardenCurrentTokenIfPresent(account: Self.accessTokenAccount) && allOK
        allOK = hardenCurrentTokenIfPresent(account: Self.refreshTokenAccount) && allOK
        guard accessGroup != nil, let legacyProjectID else { return allOK }
        allOK = hardenLegacyTokenIfPresent(
            account: "stack-auth-access-\(legacyProjectID)",
            deleteAfterHardening: false
        ) && allOK
        allOK = hardenLegacyTokenIfPresent(
            account: "stack-auth-refresh-\(legacyProjectID)",
            deleteAfterHardening: false
        ) && allOK
        return allOK
    }

    private func currentItem(account: String) -> KeychainItemAddress {
        KeychainItemAddress(
            service: service,
            account: account,
            accessGroup: accessGroup,
            usesDataProtectionKeychain: true
        )
    }

    /// The legacy Stack SDK omitted the service when adding items, which Keychain persists as the empty
    /// service; the address spells it out because an omitted query attribute would match any service.
    private func legacyItem(account: String) -> KeychainItemAddress {
        KeychainItemAddress(
            service: "",
            account: account,
            accessGroup: accessGroup,
            usesDataProtectionKeychain: false
        )
    }

    private func keychainRead(account: String) -> String? {
        let item = currentItem(account: account)
        let (status, data) = keychain.copyData(item)
        guard status == .success, let data else {
            if status != .itemNotFound {
                log.log("keychain READ status=\(status) account=\(account)")
            }
            return nil
        }
        let migrationStatus = keychain.update(item, data: nil)
        guard migrationStatus == .success else {
            log.log("keychain ACCESSIBILITY UPDATE status=\(migrationStatus) account=\(account)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let item = currentItem(account: account)
        let updateStatus = keychain.update(item, data: data)
        if updateStatus == .success { return true }
        if updateStatus != .itemNotFound {
            log.log("keychain UPDATE status=\(updateStatus) account=\(account)")
        }
        let addStatus = keychain.add(item, data: data)
        if addStatus != .success {
            log.log("keychain ADD status=\(addStatus) account=\(account)")
            return false
        }
        return true
    }

    private func keychainDelete(account: String) {
        _ = keychain.delete(currentItem(account: account))
    }

    private func keychainReadLegacy(account: String) -> String? {
        let (status, data) = keychain.copyData(legacyItem(account: account))
        guard status == .success, let data else {
            if status != .itemNotFound {
                log.log("keychain legacy READ status=\(status) account=\(account)")
            }
            return nil
        }
        guard hardenLegacyTokenIfPresent(account: account, deleteAfterHardening: false) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func hardenLegacyTokenIfPresent(account: String, deleteAfterHardening: Bool) -> Bool {
        guard accessGroup != nil else { return false }
        let status = keychain.update(legacyItem(account: account), data: nil)
        if status == .itemNotFound { return true }
        guard status == .success else {
            log.log("keychain legacy ACCESSIBILITY UPDATE status=\(status) account=\(account)")
            return false
        }
        if deleteAfterHardening { _ = keychainDeleteLegacy(account: account) }
        return true
    }

    private func hardenCurrentTokenIfPresent(account: String) -> Bool {
        let status = keychain.update(currentItem(account: account), data: nil)
        if status == .itemNotFound { return true }
        guard status == .success else {
            log.log("keychain ACCESSIBILITY PREFLIGHT status=\(status) account=\(account)")
            return false
        }
        return true
    }

    @discardableResult
    private func keychainDeleteLegacy(account: String) -> Bool {
        let status = keychain.delete(legacyItem(account: account))
        if status != .success, status != .itemNotFound {
            log.log("keychain legacy DELETE status=\(status) account=\(account)")
            return false
        }
        return true
    }
}
