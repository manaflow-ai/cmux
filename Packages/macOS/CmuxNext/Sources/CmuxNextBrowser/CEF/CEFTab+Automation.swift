public import CoreGraphics

/// Chromium's side of the automation calls of ``BrowserTab``: the full page through DevTools, the
/// cookies through the profile's cookie manager. `evaluateAsync` keeps the protocol's default
/// (Chromium's `evaluate` awaits a promise).
extension CEFTab {
    public func fullPageSnapshot() async throws -> CGImage {
        try await CEFFullPageCapture(tab: self).run()
    }

    public func cookies() async throws -> [BrowserCookie] {
        try await CEFCookieStore(tab: self).cookies()
    }

    public func setCookie(_ cookie: BrowserCookie) async throws {
        try await CEFCookieStore(tab: self).set(cookie)
    }

    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        try await CEFCookieStore(tab: self).delete(cookies)
    }
}
