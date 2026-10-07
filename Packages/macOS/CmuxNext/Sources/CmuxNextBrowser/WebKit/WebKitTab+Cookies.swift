import Foundation
import WebKit

/// Automation cookies (`browser.page.cookies.*`) in a WebKit tab's website
/// data store, which its profile shares, through ``BrowserPageAutomation``.
/// A type of its own, so `WebKitTab` stays under its line budget.
struct WebKitCookieJar {
    let tab: WebKitTab

    private var cookieStore: WKHTTPCookieStore { tab.webView.configuration.websiteDataStore.httpCookieStore }

    func cookies() async throws -> [BrowserCookie] {
        await cookieStore.allCookies().map { cookie in
            BrowserCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                          expires: cookie.expiresDate, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly)
        }
    }

    func setCookie(_ cookie: BrowserCookie) async throws {
        guard let made = cookie.httpCookie else {
            throw BrowserTabError.unsupported("Invalid cookie \(cookie.name) for \(cookie.domain)")
        }
        await cookieStore.setCookie(made)
    }

    /// Reads the store once, then deletes each match.
    func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        let doomed = Set(cookies.map { [$0.name, $0.domain, $0.path] })
        for stored in await cookieStore.allCookies() where doomed.contains([stored.name, stored.domain, stored.path]) {
            await cookieStore.deleteCookie(stored)
        }
    }
}
