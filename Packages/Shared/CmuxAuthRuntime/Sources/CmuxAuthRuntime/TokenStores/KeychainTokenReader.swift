import Foundation
#if canImport(Security)
import Security
#endif

/// Reads the Stack token pair ``KeychainStackTokenStore`` keeps for another app, and never writes it.
///
/// The read needs the other app's access group in this app's signed `keychain-access-groups`; without
/// it the data-protection Keychain answers `errSecMissingEntitlement` and ``read()`` returns nil. It
/// never shows Keychain UI.
///
/// ```swift
/// let nightly = KeychainTokenReader(service: "com.cmuxterm.app.nightly.auth",
///                                   accessGroup: "7WLXT3NR37.com.cmuxterm.app.nightly")
/// let pair = nightly.read()
/// ```
public struct KeychainTokenReader: Sendable {
    public let service: String
    public let accessGroup: String
    private let log = AuthDebugLog()

    public init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The pair, or nil when there is no refresh token or the Keychain refused the read.
    public func read() -> ImportedTokenPair? {
        ImportedTokenPair(accessToken: value(account: KeychainStackTokenStore.accessTokenAccount),
                          refreshToken: value(account: KeychainStackTokenStore.refreshTokenAccount))
    }

    private func value(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { log.log("keychain.reader READ status=\(status) account=\(account)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }
}
