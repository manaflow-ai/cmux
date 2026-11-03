public import CoreGraphics

/// WebKit's side of the automation calls of ``BrowserTab``: WebKit's `evaluateJavaScript` does not
/// await a promise, so an async body runs as a called function; the full page and the cookies come
/// from WebKit's own APIs.
extension WebKitTab {
    public func evaluateAsync(_ body: String) async throws -> BrowserJSValue {
        try await WebKitPageAutomation(tab: self).evaluateAsync(body)
    }

    public func fullPageSnapshot() async throws -> CGImage {
        try await WebKitPageAutomation(tab: self).fullPageSnapshot()
    }

    public func cookies() async throws -> [BrowserCookie] {
        await WebKitCookieStore(tab: self).cookies()
    }

    public func setCookie(_ cookie: BrowserCookie) async throws {
        try await WebKitCookieStore(tab: self).set(cookie)
    }

    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        await WebKitCookieStore(tab: self).delete(cookies)
    }
}
