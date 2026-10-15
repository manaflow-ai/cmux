public import Foundation

/// A profile's Chromium data outside any page: clearing cookies and caches,
/// and writing imported cookies, also for a profile no tab has opened yet.
/// Ported from cmux Next (`CEFEngine+BrowsingData`, `CEFRuntime+CookieImport`).
extension CEFRuntime {
    /// A first write may wait for the profile's cookie database to load.
    public static let profileDataTimeout: Duration = .seconds(60)

    /// Microseconds between 1601-01-01 (Chromium's epoch) and 1970-01-01.
    static let chromiumEpochOffset: Int64 = 11_644_473_600_000_000

    /// Whether Chromium opened the profile's request context in this process
    /// (its files stay open until quit).
    public func hasOpened(profile: UUID) -> Bool {
        openedContextKeys.contains(storage.contextKey(for: profile, offTheRecord: false))
    }

    /// Deletes the profile's cookies created at or after `since` (nil: all).
    /// - Returns: How many cookies Chromium deleted.
    @discardableResult
    public func clearCookies(profile: UUID, since: Date? = nil) async throws -> Int {
        let path = storage.cachePath(for: profile).path
        let start = since.map { Int64($0.timeIntervalSince1970 * 1_000_000) + Self.chromiumEpochOffset } ?? 0
        guard let shim else { throw CEFError.unavailable(unavailableReason ?? .notBundled) }
        let reply = try await CEFSiteReplies.shared.call(label: "cookie clear", timeout: Self.profileDataTimeout) { id in
            path.withCString { shim.clearCookies($0, id, start) }
        }
        return Int(reply.value)
    }

    /// Writes imported cookies (the shim's JSON: `BrowserChromiumCookieWrite.shimJSON`)
    /// into the profile's cookie store.
    /// - Returns: The cookies written and rejected.
    public func importCookies(json: String, profile: UUID) async throws -> (written: Int, rejected: Int) {
        let path = storage.cachePath(for: profile).path
        guard let shim else { throw CEFError.unavailable(unavailableReason ?? .notBundled) }
        let reply = try await CEFSiteReplies.shared.call(label: "cookie import", timeout: Self.profileDataTimeout) { id in
            path.withCString { pathPointer in json.withCString { shim.importCookies(pathPointer, id, $0) } }
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any],
           let written = object["written"] as? Int, let rejected = object["rejected"] as? Int {
            return (written, rejected)
        }
        return (Int(reply.value), 0)
    }

    /// Clears the HTTP cache of a profile Chromium has open, through one of its
    /// live pages (`Network.clearBrowserCache` clears the whole profile's cache).
    /// - Returns: Whether a live page of the profile cleared it.
    @discardableResult
    public func clearCache(ofOpenedProfile profile: UUID) async -> Bool {
        let key = storage.contextKey(for: profile, offTheRecord: false)
        guard let browser = liveBrowsers.first(where: { $0.contextKey == key }) else { return false }
        return (try? await browser.devTools(method: "Network.clearBrowserCache")) != nil
    }
}
