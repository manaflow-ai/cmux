import Foundation
import WebKit

/// Automation cookies (`browser.page.cookies.*`) in a WebKit tab's website
/// data store, which its profile shares. Kept out of `WebKitTab` for its
/// size; `BrowserTab.cookies`, `setCookie` and `deleteCookies` call it.
@MainActor
struct WebKitCookieStore {
    let tab: WebKitTab

    private var store: WKHTTPCookieStore { tab.webView.configuration.websiteDataStore.httpCookieStore }

    func cookies() async -> [BrowserCookie] {
        await store.allCookies().map { cookie in
            BrowserCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                          expires: cookie.expiresDate, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly)
        }
    }

    func set(_ cookie: BrowserCookie) async throws {
        guard let made = cookie.httpCookie else {
            throw BrowserTabError.unsupported("Invalid cookie \(cookie.name) for \(cookie.domain)")
        }
        await store.setCookie(made)
    }

    /// Reads the store once, then deletes each match.
    func delete(_ cookies: [BrowserCookie]) async {
        let doomed = Set(cookies.map { [$0.name, $0.domain, $0.path] })
        for stored in await store.allCookies() where doomed.contains([stored.name, stored.domain, stored.path]) {
            await store.deleteCookie(stored)
        }
    }
}
