import Foundation
import WebKit

/// Automation cookies (`browser.page.cookies.*`) in the tab's website data
/// store, which its profile shares.
extension WebKitTab {
    private var cookieStore: WKHTTPCookieStore { webView.configuration.websiteDataStore.httpCookieStore }

    public func cookies() async throws -> [BrowserCookie] {
        await cookieStore.allCookies().map { cookie in
            BrowserCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                          expires: cookie.expiresDate, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly)
        }
    }

    public func setCookie(_ cookie: BrowserCookie) async throws {
        guard let made = cookie.httpCookie else {
            throw BrowserTabError.unsupported("Invalid cookie \(cookie.name) for \(cookie.domain)")
        }
        await cookieStore.setCookie(made)
    }

    /// Reads the store once, then deletes each match.
    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        let doomed = Set(cookies.map { [$0.name, $0.domain, $0.path] })
        for stored in await cookieStore.allCookies() where doomed.contains([stored.name, stored.domain, stored.path]) {
            await cookieStore.deleteCookie(stored)
        }
    }
}
