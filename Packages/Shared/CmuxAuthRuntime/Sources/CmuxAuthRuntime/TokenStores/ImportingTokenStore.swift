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
/// The first read in a process that finds no refresh token in `primary` asks each source in order and
/// copies the first pair found into `primary`; every later read and write is `primary`'s alone. A source
/// is only ever read: signing out, a refresh and a definitive rejection change `primary` and never the
/// app the session came from. An explicit write (a sign-in, a sign-out) before the first read ends the
/// import for the process, so a sign-out is never undone by a source until the next launch.
///
/// ```swift
/// let store = ImportingTokenStore(primary: ownStore, sources: [{ nightlyKeychain.read() }])
/// ```
public actor ImportingTokenStore: StackAuthTokenStoreProtocol {
    public typealias Source = @Sendable () async -> ImportedTokenPair?

    private let primary: any StackAuthTokenStoreProtocol
    private let sources: [Source]
    private var settled = false
    private let log = AuthDebugLog()

    /// - Parameters:
    ///   - primary: The app's own store; every write goes here.
    ///   - sources: Where a session comes from when `primary` has none, in order.
    public init(primary: any StackAuthTokenStoreProtocol, sources: [Source]) {
        self.primary = primary
        self.sources = sources
    }

    private func importIfNeeded() async {
        guard !settled else { return }
        settled = true
        if let own = await primary.getStoredRefreshToken(), !own.isEmpty { return }
        for (index, source) in sources.enumerated() {
            guard let pair = await source() else { continue }
            await primary.setTokens(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
            log.log("importing.store: adopted a session from source \(index) hasAccess=\(pair.accessToken != nil)")
            return
        }
        log.log("importing.store: no source had a session")
    }

    public func getStoredAccessToken() async -> String? {
        await importIfNeeded()
        return await primary.getStoredAccessToken()
    }

    public func getStoredRefreshToken() async -> String? {
        await importIfNeeded()
        return await primary.getStoredRefreshToken()
    }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        settled = true
        await primary.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func clearTokens() async {
        settled = true
        await primary.clearTokens()
    }

    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        settled = true
        return await primary.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
    }

    public func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        await importIfNeeded()
        await primary.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                    newAccessToken: newAccessToken)
    }
}
