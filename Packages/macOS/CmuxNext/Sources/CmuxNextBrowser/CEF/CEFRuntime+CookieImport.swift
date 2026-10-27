import Foundation

/// Browser import: cookies into a profile's Chromium cookie store (shim
/// `cmux_shim_import_cookies`), also for a profile no tab has opened yet.
extension CEFRuntime {
    /// A first write may wait for the profile's cookie database to load.
    static let cookieImportTimeout: Duration = .seconds(60)

    func importCookies(_ cookies: [ChromiumCookieWrite], profile: BrowserProfileID) async throws -> ChromiumCookieWriteResult {
        guard !cookies.isEmpty else { return ChromiumCookieWriteResult(written: 0, rejected: 0) }
        guard let shim, state == .ready else { throw BrowserTabError.closed }
        let json = try ChromiumCookieWrite.shimJSON(cookies)
        let reply = try await profileWrite(profile, label: "cookie import", timeout: Self.cookieImportTimeout) { path, id in
            shim.importCookies(path, id, json)
        }
        return ChromiumCookieWriteResult.parse(reply.json) ?? ChromiumCookieWriteResult(written: Int(reply.value), rejected: 0)
    }

    /// The profile's cache path for a shim call that does not answer with a site reply (the
    /// password reveal callback); the profile counts as used, as in ``profileWrite``.
    func profileCachePath(_ profile: BrowserProfileID) -> String {
        usedProfiles.insert(profile)
        return storage.cachePath(for: profile).path
    }

    /// One write into a profile's store that the shim answers with a site
    /// reply once the profile is ready: `start` gets the profile's cache path
    /// and the reply id, and returns 1 when it started (in host mode the host's
    /// REPLY says so, as in ``siteCall(_:what:start:)``).
    func profileWrite(_ profile: BrowserProfileID, label: String, timeout: Duration,
                      start: (_ cachePath: String, _ id: Int32) -> Int32) async throws -> CEFSiteReply {
        let key = storage.cachePath(for: profile).path
        usedProfiles.insert(profile)
        let id = nextSiteReply
        nextSiteReply = nextSiteReply == .max ? 1 : nextSiteReply + 1
        siteReplyBrowsers[id] = 0
        defer {
            siteReplyBrowsers[id] = nil
            earlySiteReplies[id] = nil
        }
        let sent = sendAsync { _ in start(key, id) }
        guard try await answer(sent, label: "CEF \(label)", timeout: timeout) == 1 else { throw BrowserTabError.closed }
        if let early = earlySiteReplies[id] { return early }
        return try await siteReplies.reply(for: id, timeout: timeout) { BrowserTabError.timedOut("CEF \(label) (\(timeout))") }
    }
}
