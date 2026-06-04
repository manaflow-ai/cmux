import Foundation
#if canImport(Security)
import Security
#endif

/// Resolves the keychain service name auth tokens are stored under, namespaced
/// by bundle id so tagged dev builds don't clobber the stable app's session.
enum AuthKeychainServiceName {
    static let stableFallback = "com.cmuxterm.app.auth"

    static func make(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return stableFallback
        }
        return "\(bundleIdentifier).auth"
    }
}

/// Data-protection-keychain token store, the primary store on Release builds
/// (which carry a keychain-access-groups entitlement via
/// `Resources/cmux.entitlements`). Ad-hoc Debug builds fail keychain writes
/// with `errSecMissingEntitlement`; ``FallbackTokenStore`` detects that and
/// routes to ``FileStackTokenStore`` instead.
actor KeychainStackTokenStore: StackAuthTokenStoreProtocol {
    private static let accessTokenAccount = "cmux-auth-access-token"
    private static let refreshTokenAccount = "cmux-auth-refresh-token"
    private let service = AuthKeychainServiceName.make()
    private let log = AuthDebugLog()

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    func getStoredAccessToken() async -> String? {
        if let cachedAccessToken { return cachedAccessToken }
        return keychainRead(account: Self.accessTokenAccount)
    }

    func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return keychainRead(account: Self.refreshTokenAccount)
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        _ = await trySetTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Same as setTokens but returns whether every keychain operation
    /// actually succeeded. Used by FallbackTokenStore to decide when to
    /// give up on Keychain and route to the file store.
    func trySetTokens(accessToken: String?, refreshToken: String?) async -> Bool {
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

    func clearTokens() async {
        log.log("clearTokens called")
        cachedAccessToken = nil
        cachedRefreshToken = nil
        keychainDelete(account: Self.accessTokenAccount)
        keychainDelete(account: Self.refreshTokenAccount)
    }

    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: keychainRead(account: Self.accessTokenAccount),
            refreshToken: keychainRead(account: Self.refreshTokenAccount)
        )
        guard snapshot.matches(expectedAccessToken: accessToken, expectedRefreshToken: refreshToken) else {
            log.log("keychain.clearTokensIfCurrent: skipped stale clear")
            return false
        }
        log.log("keychain.clearTokensIfCurrent: cleared matching tokens")
        await clearTokens()
        return true
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        let current = keychainRead(account: Self.refreshTokenAccount)
        let matches = current == compareRefreshToken
        log.log("keychain.compareAndSet: matches=\(matches) hasNewRefresh=\(newRefreshToken?.isEmpty == false) hasNewAccess=\(newAccessToken?.isEmpty == false)")
        guard matches else { return }
        // Don't let the StackClientApp's error cleanup path delete both tokens.
        // If both new values are nil, it means the refresh failed and the SDK wants
        // to clear the session. Preserve the refresh token so the user stays signed in.
        if newRefreshToken == nil && newAccessToken == nil {
            log.log("keychain.compareAndSet: blocked double-nil clear (preserving session)")
            return
        }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

#if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
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
#else
    private func keychainRead(account: String) -> String? { nil }
    private func keychainWrite(_ value: String, account: String) -> Bool { false }
    private func keychainDelete(account: String) {}
#endif
}
