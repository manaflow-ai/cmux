import Foundation
#if canImport(Security)
import Security
#endif

/// SDK-compatible Stack token store keyed by Stack project id.
///
/// The vendored Stack Swift SDK's `.keychain` store writes generic-password
/// items with account names `stack-auth-access-<projectId>` and
/// `stack-auth-refresh-<projectId>` and no service attribute. iOS has used that
/// store historically, so this adapter preserves existing sessions while also
/// exposing the seeding operations needed by native Safari auth callbacks.
public actor StackProjectKeychainTokenStore: StackAuthTokenStoreProtocol {
    private let accessTokenKey: String
    private let refreshTokenKey: String

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    /// Creates a token store for the given Stack project id.
    public init(projectId: String) {
        self.accessTokenKey = "stack-auth-access-\(projectId)"
        self.refreshTokenKey = "stack-auth-refresh-\(projectId)"
    }

    /// Returns the stored Stack access token, if present.
    public func getStoredAccessToken() async -> String? {
        if let cachedAccessToken { return cachedAccessToken }
        return keychainRead(key: accessTokenKey)
    }

    /// Returns the stored Stack refresh token, if present.
    public func getStoredRefreshToken() async -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        return keychainRead(key: refreshTokenKey)
    }

    /// Stores or clears the current Stack token pair.
    public func setTokens(accessToken: String?, refreshToken: String?) async {
        var allOK = true
        if let accessToken, !accessToken.isEmpty {
            allOK = keychainWrite(accessToken, key: accessTokenKey) && allOK
        } else {
            allOK = keychainDelete(key: accessTokenKey) && allOK
        }
        if let refreshToken, !refreshToken.isEmpty {
            allOK = keychainWrite(refreshToken, key: refreshTokenKey) && allOK
        } else {
            allOK = keychainDelete(key: refreshTokenKey) && allOK
        }

        if allOK {
            cachedAccessToken = (accessToken?.isEmpty == false) ? accessToken : nil
            cachedRefreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
        } else {
            cachedAccessToken = nil
            cachedRefreshToken = nil
        }
    }

    /// Clears both stored Stack tokens.
    public func clearTokens() async {
        let accessCleared = keychainDelete(key: accessTokenKey)
        let refreshCleared = keychainDelete(key: refreshTokenKey)
        if accessCleared {
            cachedAccessToken = nil
        }
        if refreshCleared {
            cachedRefreshToken = nil
        }
    }

    /// Clears tokens only when the current stored pair matches the expected pair.
    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        let snapshot = AuthTokenSnapshot(
            accessToken: keychainRead(key: accessTokenKey),
            refreshToken: keychainRead(key: refreshTokenKey)
        )
        guard snapshot.matches(expectedAccessToken: accessToken, expectedRefreshToken: refreshToken) else {
            return false
        }
        await clearTokens()
        return true
    }

    /// Replaces tokens when the stored refresh token matches `compareRefreshToken`.
    public func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard keychainRead(key: refreshTokenKey) == compareRefreshToken else { return }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

#if canImport(Security)
    private func keychainRead(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func keychainWrite(_ value: String, key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private func keychainDelete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
#else
    private func keychainRead(key: String) -> String? { nil }
    private func keychainWrite(_ value: String, key: String) -> Bool { false }
    private func keychainDelete(key: String) -> Bool { true }
#endif
}
