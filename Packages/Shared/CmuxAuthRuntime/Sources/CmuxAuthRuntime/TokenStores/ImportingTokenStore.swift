import Foundation

/// A Stack token pair read from another store, for ``ImportingTokenStore``.
public struct ImportedTokenPair: Equatable, Sendable {
    public let accessToken: String?
    public let refreshToken: String

    /// Nil unless `refreshToken` is a non-empty token: a pair without one cannot sign in.
    public init?(accessToken: String?, refreshToken: String?) {
        guard let refreshToken, !refreshToken.isEmpty else { return nil }
        self.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        self.refreshToken = refreshToken
    }
}

/// A token store that adopts a session another app already holds when it has none of its own.
///
/// The first use in a process that finds no refresh token in `primary` asks each source in order and
/// copies the first pair found into `primary`; every later read and write is `primary`'s alone. Every
/// method waits for that one import, so no caller sees the empty store it started from and no write
/// lands under it. A source is only ever read: a refresh or a sign-out changes `primary` and never the
/// app the session came from. The adopted refresh token is the other app's own Stack session, so a
/// sign-out must not revoke it on the server: ``isShared(refreshToken:)`` says so for
/// `StackAuthClient`'s `keepsServerSession`, from the tokens this process adopted (and the refreshes of
/// them), so it still answers after the sign-out cleared `primary` and after the other app quit. A write (a sign-in, a sign-out) before the first use ends the import
/// for the process; the next launch with an empty `primary` adopts again.
///
/// ```swift
/// let store = ImportingTokenStore(primary: MemoryStackTokenStore(), sources: [{ await nightly.fetch() }])
/// ```
public actor ImportingTokenStore: StackAuthTokenStoreProtocol {
    public typealias Source = @Sendable () async -> ImportedTokenPair?

    private let primary: any StackAuthTokenStoreProtocol
    private let sources: [Source]
    private var importTask: Task<String?, Never>?
    /// Refresh tokens of sessions this process adopted, and the ones their refreshes replaced them with.
    /// Kept for the process only, never written anywhere.
    private var adopted: Set<String> = []
    private let log = AuthDebugLog()

    /// - Parameters:
    ///   - primary: The app's own store; every write goes here.
    ///   - sources: Where a session comes from when `primary` has none, in order.
    public init(primary: any StackAuthTokenStoreProtocol, sources: [Source]) {
        self.primary = primary
        self.sources = sources
    }

    /// Runs the import once per process (or not at all after an earlier write) and waits for it.
    private func settle(skippingImport: Bool = false) async {
        if importTask == nil {
            if skippingImport {
                importTask = Task { nil }
            } else {
                let primary = primary
                let sources = sources
                let log = log
                importTask = Task {
                    if let own = await primary.getStoredRefreshToken(), !own.isEmpty { return nil }
                    for (index, source) in sources.enumerated() {
                        guard let pair = await source() else { continue }
                        await primary.setTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
                        log.log("importing.store: adopted a session from source \(index) hasAccess=\(pair.accessToken != nil)")
                        return pair.refreshToken
                    }
                    log.log("importing.store: no source had a session")
                    return nil
                }
            }
        }
        if let refreshToken = await importTask?.value { adopted.insert(refreshToken) }
    }

    /// Whether `refreshToken` is another app's session, which a sign-out here must leave alive on the
    /// server: one this process adopted, or refreshed from one it adopted. The sources are not asked
    /// again, so a sign-out never fetches the other app's session.
    public func isShared(refreshToken: String) async -> Bool {
        adopted.contains(refreshToken)
    }

    public func getStoredAccessToken() async -> String? {
        await settle()
        return await primary.getStoredAccessToken()
    }

    public func getStoredRefreshToken() async -> String? {
        await settle()
        return await primary.getStoredRefreshToken()
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        await settle(skippingImport: true)
        await primary.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func clearTokens() async {
        await settle(skippingImport: true)
        await primary.clearTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        await settle(skippingImport: true)
        return await primary.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        await settle()
        await primary.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                    newAccessToken: newAccessToken)
        // A refresh of an adopted session is still the other app's session.
        if adopted.contains(compareRefreshToken), let newRefreshToken, !newRefreshToken.isEmpty,
           await primary.getStoredRefreshToken() == newRefreshToken {
            adopted.insert(newRefreshToken)
        }
    }
}
