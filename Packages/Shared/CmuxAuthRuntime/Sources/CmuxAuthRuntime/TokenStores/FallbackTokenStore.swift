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

    /// Reports whether an empty token read is trustworthy.
    ///
    /// A readable Keychain is authoritative, including when it is empty. While
    /// the primary store has not yet been ruled out, the file fallback is
    /// authoritative only when it contains a usable token; an empty fallback
    /// cannot prove that the protected Keychain is empty. Once this instance
    /// has switched to file fallback, the file store is authoritative.
    public func isStorageAvailable() async -> Bool {
        if keychainWorks {
            if await keychain.isStorageAvailable() {
                return true
            }
            guard await file.isStorageAvailable() else { return false }
            let accessToken = await file.getStoredAccessToken()
            let refreshToken = await file.getStoredRefreshToken()
            return accessToken?.isEmpty == false || refreshToken?.isEmpty == false
        }
        return await file.isStorageAvailable()
    }

    public func getStoredAccessToken() async -> String? {
        if keychainWorks {
            if let value = await keychain.getStoredAccessToken() {
                return value
            }
            return await recoverFileFallbackIfPossible().accessToken
        }
        return await file.getStoredAccessToken()
    }

    public func getStoredRefreshToken() async -> String? {
        if keychainWorks {
            if let value = await keychain.getStoredRefreshToken() {
                return value
            }
            return await recoverFileFallbackIfPossible().refreshToken
        }
        return await file.getStoredRefreshToken()
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
            // Only the definitive-rejection clear (double-nil) propagates to
            // the file store. Reads can fall back to the file store when
            // Keychain returns nil, so a matching stale file-fallback token
            // must not resurrect after the keychain clear. A successful
            // refresh must NOT be mirrored here: writing the fresh pair would
            // copy live keychain-backed credentials into the less-protected
            // file store, violating the split-brain rule that keychain
            // success clears the file store (see setTokens).
            // A NON-matching file token is intentionally preserved: it was
            // written by a newer setTokens whose keychain write failed and was
            // never rejected by the server, so clearing it here would destroy
            // a possibly-valid session. If it is invalid, the next refresh
            // definitively rejects it and this compareAndSet (routed to the
            // file store once reads flip keychainWorks) clears it then.
            if newRefreshToken == nil && newAccessToken == nil {
                await file.compareAndSet(
                    compareRefreshToken: compareRefreshToken,
                    newRefreshToken: nil,
                    newAccessToken: nil
                )
            }
            return
        }
        await file.compareAndSet(
            compareRefreshToken: compareRefreshToken,
            newRefreshToken: newRefreshToken,
            newAccessToken: newAccessToken
        )
    }

    private struct FallbackSnapshot: Sendable {
        let accessToken: String?
        let refreshToken: String?
    }

    /// Rehomes a session written while Keychain was unavailable once the
    /// signed app can read its protected store again. This keeps a temporary
    /// file fallback from becoming the permanent storage location after a
    /// signing or entitlement repair.
    private func recoverFileFallbackIfPossible() async -> FallbackSnapshot {
        let snapshot = FallbackSnapshot(
            accessToken: await file.getStoredAccessToken(),
            refreshToken: await file.getStoredRefreshToken()
        )
        guard snapshot.accessToken != nil || snapshot.refreshToken != nil else {
            return snapshot
        }

        guard await keychain.isStorageAvailable() else {
            keychainWorks = false
            log.log("keychain read missed file fallback token; switching to file fallback for this session")
            return snapshot
        }

        guard await keychain.trySetTokens(
            accessToken: snapshot.accessToken,
            refreshToken: snapshot.refreshToken
        ) else {
            keychainWorks = false
            log.log("keychain migration failed; switching to file fallback for this session")
            return snapshot
        }

        await file.clearTokens()
        log.log("keychain recovered; migrated file fallback session")
        return snapshot
    }
}
