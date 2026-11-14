import Foundation

/// A process-local write fence used by protected capture cleanup. The wrapped
/// Stack store remains the owner of persistence; once frozen, late callbacks
/// and refresh writes are rejected before they reach that owner.
public actor CaptureFencedTokenStore: StackAuthTokenStoreProtocol {
    public nonisolated let base: any StackAuthTokenStoreProtocol
    private var frozen = false
    private var freezing = false
    private var activeWriters = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var freezeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(base: any StackAuthTokenStoreProtocol) { self.base = base }
    public func getStoredAccessToken() async -> String? { await base.getStoredAccessToken() }
    public func getStoredRefreshToken() async -> String? { await base.getStoredRefreshToken() }
    public func setTokens(accessToken: String?, refreshToken: String?) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        await base.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    public func clearTokens() async {
        guard beginWrite() else { return }
        defer { endWrite() }
        await base.clearTokens()
    }
    public func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        guard beginWrite() else { return }
        defer { endWrite() }
        await base.compareAndSet(compareRefreshToken: compareRefreshToken, newRefreshToken: newRefreshToken,
                                 newAccessToken: newAccessToken)
    }
    @discardableResult
    public func clearTokensIfCurrent(accessToken: String?, refreshToken: String?) async -> Bool {
        guard beginWrite() else { return false }
        defer { endWrite() }
        return await base.clearTokensIfCurrent(accessToken: accessToken, refreshToken: refreshToken)
    }
    public func freezeForCapture() async {
        if frozen { return }
        if freezing {
            await withCheckedContinuation { freezeWaiters.append($0) }
            return
        }
        freezing = true
        await waitForWriters()
        frozen = true
        freezing = false
        let waiters = freezeWaiters
        freezeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await base.captureAwaitIdle()
    }
    public func captureAwaitIdle() async {
        await waitForWriters()
        await base.captureAwaitIdle()
    }

    private func beginWrite() -> Bool {
        guard !frozen, !freezing else { return false }
        activeWriters += 1
        return true
    }

    private func endWrite() {
        activeWriters -= 1
        guard activeWriters == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForWriters() async {
        guard activeWriters > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}

public extension StackAuthTokenStoreProtocol {
    func captureAwaitIdle() async {}
}
