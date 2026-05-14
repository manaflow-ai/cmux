import Foundation
@preconcurrency import WebKit

/// Engine-neutral cookie store. Wraps `WKHTTPCookieStore` today; the
/// Chromium backend will route to the Network Service Cookie Manager
/// (`network::mojom::CookieManager`) keyed off the same `CmuxDataStore`
/// identifier.
///
/// All access is `@MainActor` to match WebKit's isolation. Read/write
/// methods are `async` and return after the engine has acknowledged
/// the operation.
@MainActor
public final class CmuxCookieStore {
    /// The underlying WebKit cookie store. `nil` only on backends that
    /// haven't materialized a cookie store yet (e.g. the Chromium stub).
    let wkStore: WKHTTPCookieStore?

    /// Observers registered via `addObserver`. Strong-referenced so
    /// caller-side ergonomics match `WKHTTPCookieStore` (which also
    /// retains observers).
    private var observers: [ObjectIdentifier: any CmuxCookieStoreObserver] = [:]

    /// Shim that bridges WK observer callbacks back to ours. One shim
    /// per cookie store keeps registration symmetric.
    private lazy var wkObserverShim = WKObserverShim(owner: self)
    private var wkShimRegistered = false

    init(wkStore: WKHTTPCookieStore?) {
        self.wkStore = wkStore
    }

    /// All cookies currently stored. Reads from the engine's cookie
    /// store rather than `HTTPCookieStorage.shared` so it includes
    /// per-profile cookies.
    public func allCookies() async -> [HTTPCookie] {
        guard let wkStore else { return [] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            wkStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    /// Set (or overwrite) a single cookie. Returns after the engine
    /// confirms the write.
    public func setCookie(_ cookie: HTTPCookie) async {
        guard let wkStore else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wkStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    /// Delete a single cookie. The match key is (name, domain, path);
    /// other attributes are ignored. Returns after deletion completes.
    public func deleteCookie(_ cookie: HTTPCookie) async {
        guard let wkStore else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wkStore.delete(cookie) {
                continuation.resume()
            }
        }
    }

    /// Register an observer. The observer receives `cookiesDidChange`
    /// callbacks whenever the underlying store mutates. Hold a strong
    /// reference to the observer somewhere in your code — this method
    /// also retains it for symmetry with WKHTTPCookieStore.
    public func addObserver(_ observer: any CmuxCookieStoreObserver) {
        let id = ObjectIdentifier(observer)
        observers[id] = observer
        if !wkShimRegistered, let wkStore {
            wkStore.add(wkObserverShim)
            wkShimRegistered = true
        }
    }

    /// Unregister an observer. Idempotent.
    public func removeObserver(_ observer: any CmuxCookieStoreObserver) {
        let id = ObjectIdentifier(observer)
        observers.removeValue(forKey: id)
    }

    fileprivate func dispatchCookiesDidChange() {
        for (_, observer) in observers {
            observer.cookiesDidChange(in: self)
        }
    }
}

public protocol CmuxCookieStoreObserver: AnyObject {
    @MainActor
    func cookiesDidChange(in store: CmuxCookieStore)
}

private final class WKObserverShim: NSObject, WKHTTPCookieStoreObserver {
    weak var owner: CmuxCookieStore?
    init(owner: CmuxCookieStore) { self.owner = owner }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated {
            owner?.dispatchCookiesDidChange()
        }
    }
}
