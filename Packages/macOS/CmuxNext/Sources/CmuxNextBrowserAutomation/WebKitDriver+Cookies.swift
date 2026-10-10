import CmuxNextBrowser
import Foundation
import WebKit

/// Cookie calls on the app's WebKit tabs (driver-protocol.md, `cookies.*`).
/// The tabs use the person's persistent profiles, so a clear is scoped to
/// the tab's site and every clear is undoable (``CookieBackups``).
extension WebKitDriver {
    func cookiesGet(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let store = try anyTab(params).webView.configuration.websiteDataStore.httpCookieStore
        let urls = try params.strings("urls").compactMap(URL.init(string:))
        let cookies = await store.allCookies()
        return .array(cookies.filter { cookie in urls.isEmpty || urls.contains { Self.cookie(cookie, matches: $0) } }.map(Self.json))
    }

    /// `cookies.set {cookies, targetId}`: Playwright cookies (`url`, or
    /// `domain` and `path`) into the tab's store.
    func cookiesSet(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let store = try anyTab(params).webView.configuration.websiteDataStore.httpCookieStore
        var made: [HTTPCookie] = []
        for item in try params.array("cookies") {
            guard case .object(let fields) = item else { throw DriverError(.invalid, "cookies.set: cookies: expected an array of objects") }
            made.append(try Self.httpCookie(fields))
        }
        for cookie in made { await store.setCookie(cookie) }
        return .null
    }

    /// `cookies.clear {targetId, name?, domain?, path?, all?}`: deletes the
    /// cookies of the tab's site (its registrable domain and subdomains),
    /// narrowed by exact name, domain and path. The cookies go to an
    /// encrypted backup first (no backup, no clear); the answer names its
    /// restore id. `all` is refused: the store is the person's profile.
    func cookiesClear(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let dataStore = tab.webView.configuration.websiteDataStore
        guard dataStore.isPersistent else {
            // The app never lets agents drive a private (incognito) tab; a
            // private store's cookies are never written to a backup on disk.
            throw DriverError(.unsupported, "cookies.clear: private tabs are not cleared through the app")
        }
        if try params.bool("all") {
            throw DriverError(.invalid, "cookies.clear: { all: true } would clear every site in the user's browser profile, "
                + "which a session may not do; clear the current tab's site instead")
        }
        let url = tab.webView.url
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host(), !host.isEmpty else {
            throw DriverError(.invalid, "cookies.clear: the tab (\(url?.absoluteString ?? "none")) has no site to scope to; open the site first")
        }
        let site = SiteDomain.registrable(host)
        let name = try params.optionalString("name").flatMap { $0.isEmpty ? nil : $0 }
        let domain = try params.optionalString("domain").flatMap { $0.isEmpty ? nil : $0 }
        let path = try params.optionalString("path").flatMap { $0.isEmpty ? nil : $0 }
        let store = dataStore.httpCookieStore
        let matched = await store.allCookies().filter { cookie in
            Self.onSite(cookie.domain, site: site) && (name.map { $0 == cookie.name } ?? true)
                && (domain.map { $0 == cookie.domain } ?? true) && (path.map { $0 == cookie.path } ?? true)
        }
        guard !matched.isEmpty else {
            return .object(["cleared": .number(0), "restoreId": .null, "site": .string(site)])
        }
        guard let backups = cookieBackups else {
            throw DriverError(.unsupported, "cookies.clear: this app keeps no cookie backups, so it clears nothing")
        }
        backups.pruneExpired()
        let record = CookieBackupRecord(site: site, profile: tab.profileID.rawValue.uuidString,
                                        createdAt: (Date().timeIntervalSince1970 * 1000).rounded(),
                                        cookies: matched.map(BackedUpCookie.init))
        let plain: Data
        do {
            plain = try JSONEncoder().encode(record)
        } catch {
            throw DriverError(.invalid, "cookies.clear: the backup could not be encoded")
        }
        if let full = backups.full(plainBytes: plain.count) {
            throw DriverError(.forbidden, "cookies.clear: \(full)")
        }
        let restoreID: String
        do throws(CookieBackupError) {
            restoreID = try backups.save(plain)
        } catch {
            throw DriverError(.unsupported, "cookies.clear: \(error.message); nothing was cleared")
        }
        for cookie in matched { await store.deleteCookie(cookie) }
        return .object(["cleared": .number(Double(matched.count)), "restoreId": .string(restoreID), "site": .string(site)])
    }

    /// `cookies.restore {restoreId}` (no tab: the backup names its
    /// profile): puts the backed-up cookies back. A cookie set since the
    /// clear with the same name, domain and path is kept; one past its
    /// expiry is left out. The backup is deleted once restored.
    func cookiesRestore(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let restoreID = try params.string("restoreId")
        guard let backups = cookieBackups else {
            throw DriverError(.unsupported, "cookies.restore: this app keeps no cookie backups")
        }
        backups.pruneExpired()
        let record: CookieBackupRecord
        do throws(CookieBackupError) {
            let plain = try backups.load(restoreID)
            guard let decoded = try? JSONDecoder().decode(CookieBackupRecord.self, from: plain) else {
                throw CookieBackupError("the backup \(restoreID) is damaged")
            }
            record = decoded
        } catch {
            throw DriverError(.invalid, "cookies.restore: \(error.message)")
        }
        guard let uuid = UUID(uuidString: record.profile),
              let store = provider?.cookieStore(profile: BrowserProfileID(rawValue: uuid)) else {
            throw DriverError(.invalid, "cookies.restore: the store these cookies came from is closed")
        }
        let existing = Set(await store.allCookies().map { [$0.name, $0.domain, $0.path] })
        let now = Date().timeIntervalSince1970
        var restored = 0, kept = 0, expired = 0
        for cookie in record.cookies {
            if cookie.expires > 0, cookie.expires <= now {
                expired += 1
            } else if existing.contains([cookie.name, cookie.domain, cookie.path]) {
                kept += 1
            } else if let made = cookie.httpCookie {
                await store.setCookie(made)
                restored += 1
            }
        }
        do throws(CookieBackupError) {
            try backups.remove(restoreID)
        } catch {
            throw DriverError(.invalid, "cookies.restore: \(error.message)")
        }
        return .object(["restored": .number(Double(restored)), "kept": .number(Double(kept)),
                        "expired": .number(Double(expired)), "site": .string(record.site)])
    }

    /// Cookie reads with no target: the session's first tab names the profile.
    private func anyTab(_ params: DriverParams) throws(DriverError) -> WebKitTab {
        if params.has("targetId") { return try target(params).0 }
        guard let tab = provider?.automationTabs(all: false).first?.tab else {
            throw DriverError(.notFound, "\(params.method): no tab to read cookies from")
        }
        return tab
    }

    /// Whether a cookie's Domain belongs to `site` (the site or a subdomain).
    static func onSite(_ domain: String, site: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == site || host.hasSuffix("." + site)
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    private static func json(_ cookie: HTTPCookie) -> DriverJSON {
        var row: [String: DriverJSON] = [
            "name": .string(cookie.name), "value": .string(cookie.value), "domain": .string(cookie.domain),
            "path": .string(cookie.path), "httpOnly": .bool(cookie.isHTTPOnly), "secure": .bool(cookie.isSecure),
            "expires": .number(cookie.expiresDate.map { $0.timeIntervalSince1970 } ?? -1),
        ]
        if let sameSite = cookie.sameSitePolicy?.rawValue { row["sameSite"] = .string(sameSite.capitalized) }
        return .object(row)
    }

    /// A Playwright cookie as an `HTTPCookie`.
    private static func httpCookie(_ fields: [String: DriverJSON]) throws(DriverError) -> HTTPCookie {
        func text(_ key: String) -> String? { if case .string(let value)? = fields[key] { value } else { nil } }
        func flag(_ key: String) -> Bool { if case .bool(true)? = fields[key] { true } else { false } }
        guard let name = text("name"), case .string(let value)? = fields["value"] else {
            throw DriverError(.invalid, "cookies.set: each cookie needs a name and a value")
        }
        var cookie = BackedUpCookie(name: name, value: value, domain: text("domain") ?? "", path: text("path") ?? "/",
                                    expires: -1, httpOnly: flag("httpOnly"), secure: flag("secure"), sameSite: text("sameSite"))
        if case .number(let expires)? = fields["expires"] { cookie.expires = expires }
        if let raw = text("url") {
            guard let url = URL(string: raw), let host = url.host(), !host.isEmpty else {
                throw DriverError(.invalid, "cookies.set: url: expected an http(s) URL, got \(raw)")
            }
            cookie.domain = host
            if fields["path"] == nil {
                let directory = url.deletingLastPathComponent().path
                cookie.path = url.path.hasSuffix("/") ? url.path : (directory.isEmpty ? "/" : directory)
            }
        }
        guard !cookie.domain.isEmpty, let made = cookie.httpCookie else {
            throw DriverError(.invalid, "cookies.set: cookie \(name) needs a url, or a domain and a path")
        }
        return made
    }
}

/// One backed-up cookie: every field `HTTPCookie` needs to make it again.
nonisolated struct BackedUpCookie: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    /// Seconds since 1970; -1 for a session cookie.
    var expires: Double
    var httpOnly: Bool
    var secure: Bool
    var sameSite: String?

    init(name: String, value: String, domain: String, path: String, expires: Double, httpOnly: Bool, secure: Bool, sameSite: String?) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.httpOnly = httpOnly
        self.secure = secure
        self.sameSite = sameSite
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                  expires: cookie.expiresDate.map { $0.timeIntervalSince1970 } ?? -1,
                  httpOnly: cookie.isHTTPOnly, secure: cookie.isSecure, sameSite: cookie.sameSitePolicy?.rawValue)
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if expires > 0 { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite?.lowercased() {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}

/// What one backup file holds (encrypted).
nonisolated struct CookieBackupRecord: Codable, Sendable {
    var site: String
    /// The `BrowserProfileID` UUID of the store the cookies came from.
    var profile: String
    /// Milliseconds since 1970.
    var createdAt: Double
    var cookies: [BackedUpCookie]
}
