import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation
import CmuxNextAccounts

/// Reads whether the cmux browser profile a new tab would use is signed in to
/// Stripe Link (``StripeLinkCookieRule``). Chromium: a private copy of the
/// profile's `Cookies` database, columns `host_key`, `has_expires` and
/// `expires_utc` only (never a value). WebKit: the profile's cookie store,
/// for the built-in profile or one the profile book holds.
@MainActor
struct BrowserProfileLinkSession {
    let services: AppServices

    /// The wire id of the profile a new tab of the focused pane gets
    /// (the same one `LinkRouter.open(_:in: .cmuxBrowser)` uses).
    func profileForNewTab() -> String {
        guard let controller = services.linkOpener.source(tab: nil) else { return BrowserProfileRecord.defaultID }
        return services.browserProfiles.profileForNewTab(in: controller.pane.handle, on: services.machines.daemon(forPane: controller.pane),
                                                         explicit: nil)
    }

    /// Whether profile `wireID` holds a Link session cookie at `now`.
    func hasSession(profile wireID: String, now: Date = Date()) async -> Bool {
        let rule = StripeLinkCookieRule()
        let book = services.browserProfiles.book
        let engine = book.engineProfile(for: wireID)
        let file = CEFProfileStorage.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
            .cachePath(for: engine).appending(path: "Cookies")
        let chromium = await Task.detached(priority: .userInitiated) { Self.chromiumCookies(file) }.value
        if rule.hasSession(chromium, now: now) { return true }
        let store = services.cache.webKit.profileStore
        guard !store.isOffTheRecord(engine),
              engine == .default || book.profiles.contains(where: { book.engineProfile(for: $0.id) == engine }) else { return false }
        let cookies = await store.dataStore(for: engine).httpCookieStore.allCookies()
        return rule.hasSession(cookies.map { ($0.domain, $0.expiresDate) }, now: now)
    }

    /// Domain and expiry of every cookie in a Chromium `Cookies` database;
    /// empty when the file is missing or unreadable.
    nonisolated static func chromiumCookies(_ file: URL) -> [(String, Date?)] {
        guard FileManager.default.fileExists(atPath: file.path), let db = try? SQLiteSnapshot(copying: file) else { return [] }
        var rows: [(String, Date?)] = []
        try? db.query("SELECT host_key, has_expires, expires_utc FROM cookies") { row in
            let expires = row.int64(1) != 0 ? StripeLinkCookieRule.chromiumDate(row.int64(2)) : nil
            rows.append((row.string(0) ?? "", expires))
            return true
        }
        return rows
    }
}
