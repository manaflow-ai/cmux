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
        let key = storage.cachePath(for: profile).path
        usedProfiles.insert(profile)
        let id = nextSiteReply
        nextSiteReply = nextSiteReply == .max ? 1 : nextSiteReply + 1
        siteReplyBrowsers[id] = 0
        defer {
            siteReplyBrowsers[id] = nil
            earlySiteReplies[id] = nil
        }
        let started = key.withCString { path in json.withCString { shim.importCookies(path, id, $0) } }
        guard started == 1 else { throw BrowserTabError.closed }
        let reply: CEFSiteReply
        if let early = earlySiteReplies[id] {
            reply = early
        } else {
            let timeout = Self.cookieImportTimeout
            reply = try await siteReplies.reply(for: id, timeout: timeout) { BrowserTabError.timedOut("CEF cookie import (\(timeout))") }
        }
        return ChromiumCookieWriteResult.parse(reply.json) ?? ChromiumCookieWriteResult(written: Int(reply.value), rejected: 0)
    }
}
