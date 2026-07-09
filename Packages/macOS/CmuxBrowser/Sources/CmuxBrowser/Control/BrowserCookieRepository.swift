public import Foundation
public import WebKit

/// The cookie source-of-truth for the `browser cookies.*` control commands:
/// reads, writes, and deletes against a panel's `WKHTTPCookieStore`, and converts
/// between `HTTPCookie` and the cmux v2 wire dictionary.
///
/// This is the `Sendable` repository half of the browser cookie domain. The
/// owning `@MainActor` controller resolves the workspace/pane/surface and hands
/// the resolved panel's `httpCookieStore` to these methods; the repository
/// performs the bounded blocking I/O (via the injected
/// ``BrowserCookieStoreAwaiting`` seam) and the pure value mapping. Every wire
/// dictionary it produces and every `HTTPCookie` it materializes is byte-faithful
/// to the former `TerminalController.v2BrowserCookieDict(_:)`,
/// `v2BrowserCookieStoreAll/Set/Delete`, and
/// `v2BrowserCookieFromObject(_:fallbackURL:)` bodies; only the receiver moved.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`. The blocking await is expected to service the
/// store's main-actor-hopping callbacks while it blocks, exactly as the legacy
/// code did. The methods touch only the passed-in `WKHTTPCookieStore` and pure
/// Foundation values, so the type holds no per-surface mutable state.
public struct BrowserCookieRepository: Sendable {
    /// The bounded blocking-await primitive the store callbacks are driven on.
    private let awaiter: any BrowserCookieStoreAwaiting

    /// Creates a cookie repository.
    /// - Parameter awaiter: the blocking-await seam the `WKHTTPCookieStore`
    ///   callbacks are driven on (the worker-lane eval awaiter in production).
    public init(awaiter: any BrowserCookieStoreAwaiting) {
        self.awaiter = awaiter
    }

    // MARK: - Wire mapping

    /// The cmux v2 wire dictionary for a cookie.
    ///
    /// Byte-faithful to the former `v2BrowserCookieDict(_:)`: a present
    /// `expiresDate` becomes the integer seconds since the epoch, an absent one
    /// becomes `NSNull()`.
    /// - Parameter cookie: the cookie to encode.
    /// - Returns: the wire dictionary.
    public func cookieDictionary(from cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    /// Materializes an `HTTPCookie` from a raw `cookies.set` row.
    ///
    /// Byte-faithful to the former `v2BrowserCookieFromObject(_:fallbackURL:)`:
    /// the `url`/`domain`/`path` fall back to the panel's current URL, its host,
    /// and `"/"` respectively; `secure` is written as the string `"TRUE"` only
    /// when truthy; `expires` is read as a `TimeInterval` first and then an `Int`.
    /// - Parameters:
    ///   - raw: the raw cookie row from the request.
    ///   - fallbackURL: the panel's current URL, used to fill missing `url`/`domain`.
    /// - Returns: the cookie, or `nil` if `HTTPCookie` rejects the assembled
    ///   properties.
    public func cookie(from raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    // MARK: - Store I/O

    /// Reads every cookie from the store, blocking until the callback fires.
    ///
    /// Byte-faithful to the former `v2BrowserCookieStoreAll`: returns the
    /// delivered cookies, or `nil` if the callback did not fire within `timeout`.
    /// - Parameters:
    ///   - store: the panel's cookie store.
    ///   - timeout: the maximum time to block, in seconds (default `3.0`).
    /// - Returns: the cookies, or `nil` on timeout.
    public func allCookies(in store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        awaiter.await(timeout: timeout) { finish in
            // `WKHTTPCookieStore` I/O is `@MainActor`-isolated. The await runs on
            // a worker thread and blocks while the main run loop services the
            // store's main-actor-hopping callback, so the call must be *initiated*
            // on main without blocking it: hop via `DispatchQueue.main.async`,
            // then `MainActor.assumeIsolated` (we are provably on main inside the
            // hop) to call the isolated method. Same `DispatchQueue.main.async` /
            // `MainActor.assumeIsolated` bridge the legacy worker-lane control
            // commands used.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store.getAllCookies { items in
                        finish(items)
                    }
                }
            }
        }
    }

    /// Writes a cookie to the store, blocking until the callback fires.
    ///
    /// Byte-faithful to the former `v2BrowserCookieStoreSet`: returns `true` when
    /// the set callback fired within `timeout`, `false` on timeout.
    /// - Parameters:
    ///   - cookie: the cookie to write.
    ///   - store: the panel's cookie store.
    ///   - timeout: the maximum time to block, in seconds (default `3.0`).
    /// - Returns: whether the write completed in time.
    public func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> Bool {
        awaiter.await(timeout: timeout) { finish in
            // See `allCookies(in:timeout:)`: `WKHTTPCookieStore` is `@MainActor`,
            // so initiate the write on main via the `DispatchQueue.main.async` /
            // `MainActor.assumeIsolated` bridge while the worker thread blocks.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store.setCookie(cookie) {
                        finish(true)
                    }
                }
            }
        } ?? false
    }

    /// Deletes a cookie from the store, blocking until the callback fires.
    ///
    /// Byte-faithful to the former `v2BrowserCookieStoreDelete`: returns `true`
    /// when the delete callback fired within `timeout`, `false` on timeout.
    /// - Parameters:
    ///   - cookie: the cookie to delete.
    ///   - store: the panel's cookie store.
    ///   - timeout: the maximum time to block, in seconds (default `3.0`).
    /// - Returns: whether the delete completed in time.
    public func deleteCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> Bool {
        awaiter.await(timeout: timeout) { finish in
            // See `allCookies(in:timeout:)`: `WKHTTPCookieStore` is `@MainActor`,
            // so initiate the delete on main via the `DispatchQueue.main.async` /
            // `MainActor.assumeIsolated` bridge while the worker thread blocks.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store.delete(cookie) {
                        finish(true)
                    }
                }
            }
        } ?? false
    }
}
