import Foundation

/// A token store that keeps its pair in this process only: nothing reaches the Keychain, a file or a log.
///
/// For a session adopted from another app (``ImportingTokenStore``), which this app must never write to
/// disk: the next launch adopts it again, or has none.
///
/// ```swift
/// let store = ImportingTokenStore(primary: MemoryStackTokenStore(), sources: [{ await handoff.fetch() }])
/// ```
public actor MemoryStackTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?

    /// Creates an empty store.
    public init() {}

    public func getStoredAccessToken() async -> String? { accessToken }

    public func getStoredRefreshToken() async -> String? { refreshToken }

    public func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = (accessToken?.isEmpty == false) ? accessToken : nil
        self.refreshToken = (refreshToken?.isEmpty == false) ? refreshToken : nil
    }

    public func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    public func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        guard refreshToken == compareRefreshToken else { return }
        await setTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
    }
}
