import Foundation

/// Composite store that routes to Keychain first and transparently falls
/// back to the file store if Keychain signals a real failure (empirically:
/// errSecMissingEntitlement -34018 on ad-hoc macOS Debug builds without a
/// matching keychain-access-groups entry in the signed entitlements). Keeps
/// writes split-brain-free by clearing the file store whenever Keychain
/// succeeds.
public actor FallbackTokenStore: StackAuthTokenStoreProtocol {
    private let keychain: KeychainStackTokenStore
    private let file: FileStackTokenStore
    private let log = AuthDebugLog()
    private var keychainWorks: Bool = true

    /// Creates the composite store.
    /// - Parameters:
    ///   - keychain: The primary keychain-backed store.
    ///   - file: The fallback file-backed store.
    public init(primary keychain: KeychainStackTokenStore, fallback file: FileStackTokenStore) {
        self.keychain = keychain
        self.file = file
    }

    public func getStoredAccessToken() async -> String? {
        if keychainWorks, let value = await keychain.getStoredAccessToken() {
            return value
        }
        let fallbackValue = await file.getStoredAccessToken()
        if keychainWorks, fallbackValue != nil {
            keychainWorks = false
            log.log("keychain read missed file fallback token; switching to file fallback for this session")
        }
        return fallbackValue
    }

    public func getStoredRefreshToken() async -> String? {
        if keychainWorks, let value = await keychain.getStoredRefreshToken() {
            return value
        }
        let fallbackValue = await file.getStoredRefreshToken()
        if keychainWorks, fallbackValue != nil {
            keychainWorks = false
            log.log("keychain read missed file fallback token; switching to file fallback for this session")
        }
        return fallbackValue
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        if keychainWorks {
            let ok = await keychain.trySetTokens(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            if ok {
                await file.clearTokens()
                return
            }
            keychainWorks = false
            log.log("keychain write failed; switching to file fallback for this session")
        }
        await file.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func clearTokens() async {
        await keychain.clearTokens()
        await file.clearTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        if keychainWorks {
            let keychainCleared = await keychain.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
            let fileCleared = await file.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
            return keychainCleared || fileCleared
        }
        return await file.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        if keychainWorks {
            if await keychain.getStoredRefreshToken() != compareRefreshToken,
               await file.getStoredRefreshToken() == compareRefreshToken {
                keychainWorks = false
                log.log("keychain compare missed file fallback token; switching to file fallback for this session")
                await file.compareAndSet(
                    compareRefreshToken: compareRefreshToken,
                    newRefreshToken: newRefreshToken,
                    newAccessToken: newAccessToken
                )
                return
            }
            await keychain.compareAndSet(
                compareRefreshToken: compareRefreshToken,
                newRefreshToken: newRefreshToken,
                newAccessToken: newAccessToken
            )
            // Reads can fall back to the file store when Keychain returns nil;
            // apply the same compare-guarded mutation so a matching stale
            // file-fallback token cannot resurrect after the keychain path.
            await file.compareAndSet(
                compareRefreshToken: compareRefreshToken,
                newRefreshToken: newRefreshToken,
                newAccessToken: newAccessToken
            )
            return
        }
        await file.compareAndSet(
            compareRefreshToken: compareRefreshToken,
            newRefreshToken: newRefreshToken,
            newAccessToken: newAccessToken
        )
    }
}
