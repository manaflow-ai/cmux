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
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
        ]
        if cookie.secure { properties[.secure] = "TRUE" }
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        guard let made = HTTPCookie(properties: properties) else {
            throw BrowserTabError.unsupported("Invalid cookie \(cookie.name) for \(cookie.domain)")
        }
        await cookieStore.setCookie(made)
    }

    public func deleteCookie(_ cookie: BrowserCookie) async throws {
        for stored in await cookieStore.allCookies()
        where stored.name == cookie.name && stored.domain == cookie.domain && stored.path == cookie.path {
            await cookieStore.deleteCookie(stored)
        }
    }
}
