public import WebKit

/// Data stores created for `session.configure({ proxy })`, by the session
/// that configured them. While that session lives a store keeps the proxy
/// it was given, and the browser's own proxy handling (the system proxy
/// mirror, a remote workspace's proxy) leaves it alone (``owns(_:)``).
///
/// The proxy is the agent's, so it ends with the session
/// (``sessionEnded(_:)``): a tab the session kept (the user's from then
/// on), and a tab the user opened from it on the same store, must not keep
/// sending its traffic through a server the agent chose. The store itself
/// stays (the tab keeps its private cookies and storage); its proxy is
/// cleared and the browser's proxy handling takes it back.
@MainActor
public final class BrowserReplProxyStores {
    public static let shared = BrowserReplProxyStores()

    private var stores: [(store: WeakStore, sessionID: String)] = []

    private final class WeakStore {
        weak var store: WKWebsiteDataStore?
        init(_ store: WKWebsiteDataStore) { self.store = store }
    }

    public init() {}

    /// Records `store` as `sessionID`'s proxy store.
    public func register(_ store: WKWebsiteDataStore, sessionID: String) {
        prune()
        stores.append((WeakStore(store), sessionID))
    }

    /// Whether `store` is a live session's proxy store.
    public func owns(_ store: WKWebsiteDataStore) -> Bool {
        stores.contains { $0.store.store === store }
    }

    /// Clears the proxy of every store `sessionID` configured and hands
    /// them back to the browser's proxy handling.
    /// - Returns: Whether any store of the session was still in use, so
    ///   the caller has the browser apply its own proxy settings to it.
    @discardableResult
    public func sessionEnded(_ sessionID: String) -> Bool {
        var released = false
        stores.removeAll { entry in
            guard entry.sessionID == sessionID else { return false }
            if let store = entry.store.store {
                store.proxyConfigurations = []
                released = true
            }
            return true
        }
        return released
    }

    private func prune() {
        stores.removeAll { $0.store.store == nil }
    }
}
