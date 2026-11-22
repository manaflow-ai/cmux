import Foundation

extension CEFEngine {
    /// Stores imported cookies in `profile`'s Chromium cookie jar. Starts
    /// Chromium when it is not running yet (the framework loads off the main
    /// thread). Throws `engineUnavailable` when Chromium cannot start.
    public func importCookies(_ cookies: [ChromiumCookieWrite], into profile: BrowserProfileID) async throws -> ChromiumCookieWriteResult {
        try await CEFRuntime.shared.start(layout: layout, trigger: "cookieImport")
        return try await CEFRuntime.shared.importCookies(cookies, profile: profile)
    }
}
