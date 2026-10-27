public import CmuxNextSettings
import Foundation

/// `browser.page.cookies.get|set|clear` and `browser.page.storage.get|set|clear`:
/// the old `cmux browser cookies` and `cmux browser storage`. Cookies belong
/// to the tab's profile (its engine's store), which is the person's, so a
/// clear stays on the tab's site and `all` is refused, as the driver's
/// `cookies.clear` does; storage is the page's `localStorage` or
/// `sessionStorage`. A cookie or storage write is the agent's own page code for the login guard:
/// refused on a site holding a filled sign-in, and the site takes no Secure Store fill afterwards
/// (``BrowserLoginGuards``).
extension BrowserPageService {
    func cookieAndStorageMethods() -> [ControlMethod] {
        let engine = engine
        let guards = loginGuards
        return [
            .async("browser.page.cookies.get") { call in
                let tab = try Self.tab(call)
                let filter = try CookieFilter(call.request.params)
                let now = Date()
                let cookies = try await Self.cookies(engine, tab).filter { filter.listed($0, now: now) }
                var result: [String: JSONValue] = Self.base(tab)
                result["cookies"] = .array(cookies.map(\.json))
                return .object(result)
            },
            .async("browser.page.cookies.set") { call in
                let tab = try Self.tab(call)
                let cookies = try Self.cookiesToSet(call, tab: tab)
                _ = try await Self.guardedAgentScript(engine, tab, guards) { try await Self.run(engine, .cookies(.set(cookies)), tab) }
                var result: [String: JSONValue] = Self.base(tab)
                result["set"] = JSONValue(cookies.count)
                return .object(result)
            },
            .async("browser.page.cookies.clear") { call in
                let tab = try Self.tab(call)
                let filter = try CookieFilter(call.request.params)
                let all = try CookieFilter.flag(call.request.params, "all") == true
                guard all != filter.hasScope else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.cookiesClearScope",
                                                                         "browser.page.cookies.clear takes exactly one of params.all or a cookie scope (name, url, domain, path)"))
                }
                guard !all else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.cookiesClearAll",
                                                                         "params.all would clear every site in the person's browser profile; clear the tab's site instead"))
                }
                let site = try Self.site(tab)
                let now = Date()
                let doomed = try await Self.cookies(engine, tab).filter { $0.isOnSite(site) && filter.cleared($0, now: now) }
                if !doomed.isEmpty {
                    _ = try await Self.guardedAgentScript(engine, tab, guards) { try await Self.run(engine, .cookies(.delete(doomed)), tab) }
                }
                var result: [String: JSONValue] = Self.base(tab)
                result["cleared"] = JSONValue(doomed.count)
                return .object(result)
            },
            storage("get", engine: engine, guards: nil) { call, area in
                guard let raw = call.request.params["key"], raw != .null else { return .get(area, key: nil) }
                guard let key = raw.stringValue else { throw CookieFilter.wrongType("key") }
                return .get(area, key: key)
            },
            storage("set", engine: engine, guards: guards) { call, area in
                .set(area, key: try Self.string(call, "key"), value: try Self.storageValue(call))
            },
            storage("clear", engine: engine, guards: guards) { _, area in .clear(area) },
        ]
    }

    /// `guards`: the login guard for a write (nil for a read).
    private func storage(_ name: String, engine: any BrowserPageEngine, guards: BrowserLoginGuards?,
                         _ make: @escaping @Sendable (ControlCall, BrowserPageScripts.StorageArea) throws -> BrowserPageScripts.StorageOperation) -> ControlMethod {
        .async("browser.page.storage.\(name)") { call in
            let tab = try Self.tab(call)
            let area = try Self.storageArea(call)
            let operation = try make(call, area)
            let value = try await Self.guardedAgentScript(engine, tab, guards) {
                try await Self.run(engine, .evaluate(BrowserPageScripts.storage(operation)), tab)
            }["value"] ?? .null
            if let error = value["error"]?.stringValue {
                throw ControlError(code: "invalid_state", message: error)
            }
            var result: [String: JSONValue] = Self.base(tab)
            result["type"] = .string(area.rawValue)
            let payload = value["value"] ?? .null
            for key in ["key", "value", "cleared"] {
                if let value = payload[key] { result[key] = value }
            }
            return .object(result)
        }
    }

    /// `type` (or `storage`, as the old CLI also read): `local` by default.
    static func storageArea(_ call: ControlCall) throws -> BrowserPageScripts.StorageArea {
        let params = call.request.params
        guard let raw = params["type"] ?? params["storage"], raw != .null else { return .local }
        guard let text = raw.stringValue,
              let area = BrowserPageScripts.StorageArea(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ControlError.invalidParams(ControlStrings.text("control.error.storageType", "params.type is local or session"))
        }
        return area
    }

    /// A string, or a number or boolean as its text (as the old CLI stored it).
    static func storageValue(_ call: ControlCall) throws -> String {
        switch call.request.params["value"] {
        case .string(let text)?: return text
        case .number(let number)?:
            if abs(number) < 1e15, let whole = Int(exactly: number) { return String(whole) }
            return String(number)
        case .bool(let flag)?: return flag ? "true" : "false"
        default:
            throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", call.request.method, "value"))
        }
    }

    static func cookies(_ engine: any BrowserPageEngine, _ tab: Tab) async throws -> [BrowserPageCookie] {
        guard case .array(let list)? = try await run(engine, .cookies(.list), tab)["cookies"] else { return [] }
        return list.compactMap(BrowserPageCookie.init(json:))
    }

    /// The host of the tab's http(s) page, the site a clear is scoped to.
    static func site(_ tab: Tab) throws -> String {
        guard let url = tab.url.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw ControlError(code: "invalid_state", message: ControlStrings.text("control.error.cookiesClearNoSite",
                                                                                 "The tab shows no http(s) page, so a clear has no site to scope to; open the site first"))
        }
        return host
    }

    /// One cookie from `name`, `value`, … or several from `cookies: [{…}]`.
    /// The domain is `domain`, else `url`'s host, else the tab's page (the
    /// old precedence); a domain without a leading dot is host-only.
    static func cookiesToSet(_ call: ControlCall, tab: Tab) throws -> [BrowserPageCookie] {
        let params = call.request.params
        let entries: [JSONValue]
        if case .array(let list)? = params["cookies"] { entries = list } else { entries = [.object(params)] }
        let missing = ControlError.invalidParams(ControlStrings.text("control.error.cookiePayload",
                                                                     "Each cookie needs a name and a value, and a url, a domain or a tab with a page"))
        guard !entries.isEmpty else { throw missing }
        return try entries.map { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty, let value = entry["value"]?.stringValue else { throw missing }
            guard [name, value, entry["path"]?.stringValue ?? "/"].allSatisfy(isHeaderSafe) else {
                throw ControlError.invalidParams(ControlStrings.text("control.error.cookieUnsafe",
                                                                     "Cookie names, values and paths cannot contain ';', line breaks or control characters"))
            }
            if let expires = entry["expires"]?.doubleValue, expires <= Date().timeIntervalSince1970 {
                throw ControlError.invalidParams(ControlStrings.text("control.error.cookieExpired",
                                                                     "An expired cookie would delete a cookie; use browser.page.cookies.clear instead"))
            }
            let url = try CookieFilter.url(entry["url"])
            let given = entry["domain"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            guard let domain = given ?? url?.host ?? tab.url.flatMap(URL.init(string:))?.host, !domain.isEmpty, isHeaderSafe(domain) else {
                throw missing
            }
            return BrowserPageCookie(name: name, value: value, domain: domain, path: entry["path"]?.stringValue ?? "/",
                                     expires: entry["expires"]?.doubleValue, secure: entry["secure"]?.boolValue ?? false,
                                     httpOnly: entry["httpOnly"]?.boolValue ?? entry["http_only"]?.boolValue ?? false)
        }
    }

    /// No `;`, CR, LF or other control characters, which would split a `Set-Cookie` header.
    static func isHeaderSafe(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value == 0x3B || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// The old CLI's cookie filters. Listing: `name` exact, `domain` a
    /// substring, `path` exact. Clearing: `name` exact, `domain` that domain
    /// or a subdomain, `path` exact. Both take `url` (the cookies a request
    /// there carries) and match `value`, `secure`, `httpOnly` and `expires`
    /// (Unix seconds) exactly. A filter of the wrong type is refused, not
    /// ignored, so a clear never widens.
    struct CookieFilter {
        var name: String?
        var value: String?
        var url: URL?
        var domain: String?
        var path: String?
        var secure: Bool?
        var httpOnly: Bool?
        var expires: Double?

        init(_ params: [String: JSONValue]) throws {
            func text(_ key: String) throws -> String? {
                guard let raw = params[key], raw != .null else { return nil }
                guard let text = raw.stringValue else { throw Self.wrongType(key) }
                return text.isEmpty ? nil : text
            }
            name = try text("name")
            value = params["value"]?.stringValue
            if let raw = params["value"], raw != .null, value == nil { throw Self.wrongType("value") }
            url = try Self.url(params["url"])
            domain = try text("domain")
            path = try text("path")
            secure = try Self.flag(params, "secure")
            httpOnly = try Self.flag(params, "httpOnly") ?? Self.flag(params, "http_only")
            if let raw = params["expires"], raw != .null {
                guard let seconds = raw.doubleValue else { throw Self.wrongType("expires") }
                expires = seconds.rounded(.down)
            }
        }

        /// An absolute http(s) URL with a host, or nil when absent.
        static func url(_ raw: JSONValue?) throws -> URL? {
            guard let raw, raw != .null else { return nil }
            guard let text = raw.stringValue else { throw wrongType("url") }
            if text.isEmpty { return nil }
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
                throw ControlError(code: "invalid_params",
                                   message: ControlStrings.format("control.error.cookieURL", "params.url needs a scheme and a host, such as https://%@/", text),
                                   data: ["param": "url"])
            }
            return url
        }

        /// A boolean param, nil when absent.
        static func flag(_ params: [String: JSONValue], _ key: String) throws -> Bool? {
            guard let raw = params[key], raw != .null else { return nil }
            guard let flag = raw.boolValue else { throw wrongType(key) }
            return flag
        }

        static func wrongType(_ key: String) -> ControlError {
            ControlError(code: "invalid_params", message: ControlStrings.format("control.error.cookieParam", "params.%@ has the wrong type", key),
                         data: ["param": .string(key)])
        }

        var hasScope: Bool {
            name != nil || url != nil || domain != nil || path != nil || value != nil || secure != nil || httpOnly != nil || expires != nil
        }

        private func matchesExactFields(_ cookie: BrowserPageCookie) -> Bool {
            (name.map { cookie.name == $0 } ?? true)
                && (value.map { cookie.value == $0 } ?? true)
                && (path.map { cookie.path == $0 } ?? true)
                && (secure.map { cookie.secure == $0 } ?? true)
                && (httpOnly.map { cookie.httpOnly == $0 } ?? true)
                && (expires.map { cookie.expires?.rounded(.down) == $0 } ?? true)
        }

        func listed(_ cookie: BrowserPageCookie, now: Date) -> Bool {
            matchesExactFields(cookie)
                && (url.map { cookie.isSent(to: $0, now: now) } ?? true)
                && (domain.map { cookie.domain.localizedCaseInsensitiveContains($0) } ?? true)
        }

        func cleared(_ cookie: BrowserPageCookie, now: Date) -> Bool {
            matchesExactFields(cookie)
                && (url.map { cookie.isSent(to: $0, now: now) } ?? true)
                && (domain.map { cookie.isIn(domain: $0) } ?? true)
        }
    }
}
