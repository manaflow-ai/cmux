import CmuxAuthRuntime
import Foundation

/// A token store that can say a refresh token is another app's session, which a sign-out here must leave
/// alive on the server (`StackAuthClient`'s `keepsServerSession`).
protocol KeepsSharedSessions: Sendable {
    func isShared(refreshToken: String) async -> Bool
}

extension ImportingTokenStore: KeepsSharedSessions {}

/// The token store of a Team-signed production build that shares its session with the others (Rust's
/// `shared_session`, cmux-cloud-config `config`): this build's own store, plus the one shared item in the
/// Keychain access group every such build carries (`7WLXT3NR37.com.cmuxterm.app.shared`).
///
/// - Its own session always wins: when `own` holds a refresh token (its Keychain store, or a namespaced
///   store `own` adopts once), the shared item is never read.
/// - Signed out at launch, it imports the shared item read-only, in memory: the pair never reaches `own`,
///   a refresh of it stays in memory, and a sign-out forgets it without touching the item. The session is
///   the writer's, so ``isShared(refreshToken:)`` answers true for it and a sign-out leaves it alive on the
///   server, exactly as a NEXT DEV adoption of NIGHTLY's session does (``ImportingTokenStore``).
/// - It writes its OWN session to the item after a sign-in or a refresh (never an imported one), and on its
///   sign-out removes the item only while it still holds that session (another build may have written its
///   own since).
///
/// A build signed without the access group (ad hoc, or a profile that lacks it) gets
/// `errSecMissingEntitlement` from every query on the item: nothing is imported and nothing written.
actor SharedSessionTokenStore: StackAuthTokenStoreProtocol, KeepsSharedSessions {
    private let own: any StackAuthTokenStoreProtocol
    private let shared: any StackAuthTokenStoreProtocol
    private let imported = MemoryStackTokenStore()
    private var importTask: Task<String?, Never>?
    private var importApplied = false
    /// Whether the session in use is the imported one (in ``imported``), not this build's own.
    private var usesImported = false
    /// Refresh tokens of the imported session and its refreshes, for this process only.
    private var importedTokens: Set<String> = []
    private let log = AuthDebugLog()

    /// - Parameters:
    ///   - own: This build's store; every session it signs in to is written here.
    ///   - shared: The shared item's store (its Keychain service and access group).
    init(own: any StackAuthTokenStoreProtocol, shared: any StackAuthTokenStoreProtocol) {
        self.own = own
        self.shared = shared
    }

    /// Runs the import once per process (or not at all after an earlier write) and waits for it.
    private func settle(skippingImport: Bool = false) async {
        if importTask == nil {
            if skippingImport {
                importTask = Task { nil }
            } else {
                let own = own
                let shared = shared
                let imported = imported
                let log = log
                importTask = Task {
                    if let mine = await own.getStoredRefreshToken(), !mine.isEmpty { return nil }
                    guard let pair = ImportedTokenPair(
                        accessToken: await shared.getStoredAccessToken(),
                        refreshToken: await shared.getStoredRefreshToken()
                    ) else { return nil }
                    await imported.setTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
                    log.log("shared.store: imported the shared session hasAccess=\(pair.accessToken != nil)")
                    return pair.refreshToken
                }
            }
        }
        guard let task = importTask else { return }
        let token = await task.value
        guard !importApplied else { return }
        importApplied = true
        if let token {
            importedTokens.insert(token)
            usesImported = true
        }
    }

    private var active: any StackAuthTokenStoreProtocol { usesImported ? imported : own }

    func isShared(refreshToken: String) async -> Bool { importedTokens.contains(refreshToken) }

    func tokenReadFailureCount() async -> UInt64 { await own.tokenReadFailureCount() }

    func captureAwaitIdle() async { await own.captureAwaitIdle() }

    func getStoredAccessToken() async -> String? {
        await settle()
        return await active.getStoredAccessToken()
    }

    func getStoredRefreshToken() async -> String? {
        await settle()
        return await active.getStoredRefreshToken()
    }

    /// A sign-in (a pair this build was given) goes to `own` and is shared; seeding the imported pair again
    /// keeps it in memory.
    func setTokens(accessToken: String?, refreshToken: String?) async {
        await settle(skippingImport: true)
        if usesImported, let refreshToken, importedTokens.contains(refreshToken) {
            await imported.setTokens(accessToken: accessToken, refreshToken: refreshToken)
            return
        }
        if usesImported {
            usesImported = false
            await imported.clearTokens()
        }
        let before = await ownPair()
        await own.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        await share(after: before)
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        await settle()
        if usesImported {
            await imported.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                         newAccessToken: newAccessToken)
            let current = await imported.getStoredRefreshToken()
            // A refresh of the imported session is still the writer's session.
            if importedTokens.contains(compareRefreshToken), let current { importedTokens.insert(current) }
            // A definitive rejection cleared it: signed out, the item left as it is.
            if current == nil { usesImported = false }
            return
        }
        let before = await ownPair()
        await own.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                newAccessToken: newAccessToken)
        await share(after: before)
    }

    func clearTokens() async {
        await settle(skippingImport: true)
        if usesImported {
            usesImported = false
            await imported.clearTokens()
            await own.clearTokens()
            return
        }
        let before = await own.getStoredRefreshToken()
        await own.clearTokens()
        await withdraw(before)
    }

    @discardableResult
    func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        await settle(skippingImport: true)
        if usesImported {
            let cleared = await imported.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
            if cleared { usesImported = false }
            return cleared
        }
        let before = await own.getStoredRefreshToken()
        let cleared = await own.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
        if cleared { await withdraw(before) }
        return cleared
    }

    private func ownPair() async -> (access: String?, refresh: String?) {
        (await own.getStoredAccessToken(), await own.getStoredRefreshToken())
    }

    /// Writes this build's own session to the shared item when a write changed it; a write that left `own`
    /// empty (a definitive rejection) removes the item while it still holds the old session.
    private func share(after before: (access: String?, refresh: String?)) async {
        let now = await ownPair()
        guard now.access != before.access || now.refresh != before.refresh else { return }
        if let refresh = now.refresh, !refresh.isEmpty {
            await shared.setTokens(accessToken: now.access, refreshToken: refresh)
        } else {
            await withdraw(before.refresh)
        }
    }

    /// Removes the shared item only while it still holds `refreshToken` (this build's session).
    private func withdraw(_ refreshToken: String?) async {
        guard let refreshToken, !refreshToken.isEmpty else { return }
        await shared.clearTokensIfCurrent(accessToken: nil, refreshToken: refreshToken)
    }
}
