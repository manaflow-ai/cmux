public import CoreGraphics

/// What page automation needs beyond ``BrowserTab``: an awaited async
/// script (`browser.page.wait`), the pixels of the whole document
/// (`browser.page.screenshot --full-page`) and the profile's cookies
/// (`browser.page.cookies.*`). Each engine's way lives in its own type
/// (`WebKitPageAutomation`, `CEFFullPageCapture`, `WebKitCookieJar`,
/// `CEFCookieJar`), so the tab types and the protocol do not grow.
@MainActor
public struct BrowserPageAutomation {
    let tab: any BrowserTab

    public init(_ tab: any BrowserTab) {
        self.tab = tab
    }

    /// Runs `body` as an async function in the page world and returns what
    /// it resolves to.
    public func evaluateAsync(_ body: String) async throws -> BrowserJSValue {
        if let webKit = tab as? WebKitTab {
            return try await WebKitPageAutomation(tab: webKit).evaluateAsync(body)
        }
        // Engines whose `evaluate` awaits a returned promise.
        return try await tab.evaluate("(async () => {\n\(body)\n})()", world: .page)
    }

    /// Pixels of the whole document, not only the viewport.
    public func fullPageSnapshot() async throws -> CGImage {
        switch tab {
        case let webKit as WebKitTab: return try await WebKitPageAutomation(tab: webKit).fullPageSnapshot()
        case let cef as CEFTab: return try await CEFFullPageCapture(tab: cef).image()
        default: throw BrowserTabError.snapshotUnavailable
        }
    }

    /// Every cookie of the tab's profile. A tab with no engine store (a
    /// hibernated or still-starting one) throws `unsupported("cookies")`.
    public func cookies() async throws -> [BrowserCookie] {
        switch tab {
        case let webKit as WebKitTab: return try await WebKitCookieJar(tab: webKit).cookies()
        case let cef as CEFTab: return try await CEFCookieJar(tab: cef).cookies()
        default: throw BrowserTabError.unsupported("cookies")
        }
    }

    /// Stores `cookie` in the tab's profile.
    public func setCookie(_ cookie: BrowserCookie) async throws {
        switch tab {
        case let webKit as WebKitTab: try await WebKitCookieJar(tab: webKit).setCookie(cookie)
        case let cef as CEFTab: try await CEFCookieJar(tab: cef).setCookie(cookie)
        default: throw BrowserTabError.unsupported("cookies")
        }
    }

    /// Deletes the cookies with each one's name, domain and path.
    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        switch tab {
        case let webKit as WebKitTab: try await WebKitCookieJar(tab: webKit).deleteCookies(cookies)
        case let cef as CEFTab: try await CEFCookieJar(tab: cef).deleteCookies(cookies)
        default: throw BrowserTabError.unsupported("cookies")
        }
    }
}
