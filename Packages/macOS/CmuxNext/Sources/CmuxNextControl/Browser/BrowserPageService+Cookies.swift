public import CmuxNextSettings
import Foundation

/// `browser.page.cookies.get|set|clear` and `browser.page.storage.get|set|clear`:
/// the old `cmux browser cookies` and `cmux browser storage`. Cookies belong
/// to the tab's profile (its engine's store); storage is the page's
/// `localStorage` or `sessionStorage`.
extension BrowserPageService {
    func cookieAndStorageMethods() -> [ControlMethod] {
        let engine = engine
        return [
            .async("browser.page.cookies.get") { call in
                let tab = try Self.tab(call)
                let filter = CookieFilter(call.request.params)
                let cookies = try await Self.cookies(engine, tab).filter(filter.listed)
                var result = Self.base(tab)
                result["cookies"] = .array(cookies.map(\.json))
                return .object(result)
            },
            .async("browser.page.cookies.set") { call in
                let tab = try Self.tab(call)
                let cookies = try Self.cookiesToSet(call, tab: tab)
                _ = try await Self.run(engine, .cookies(.set(cookies)), tab)
                var result = Self.base(tab)
                result["set"] = JSONValue(cookies.count)
                return .object(result)
            },
            .async("browser.page.cookies.clear") { call in
                let tab = try Self.tab(call)
                let filter = CookieFilter(call.request.params)
                let all = call.request.params["all"]?.boolValue == true
                guard all != filter.hasScope else {
                    throw ControlError.invalidParams(ControlStrings.text("control.error.cookiesClearScope",
                                                                         "browser.page.cookies.clear takes exactly one of params.all or a cookie scope (name, url, domain, path)"))
                }
                let now = Date()
                let doomed = try await Self.cookies(engine, tab).filter { all || filter.cleared($0, now: now) }
                if !doomed.isEmpty { _ = try await Self.run(engine, .cookies(.delete(doomed)), tab) }
                var result = Self.base(tab)
                result["cleared"] = JSONValue(doomed.count)
                return .object(result)
            },
            storage("get", engine: engine) { call, area in
                .get(area, key: call.request.params["key"]?.stringValue)
            },
            storage("set", engine: engine) { call, area in
                .set(area, key: try Self.string(call, "key"), value: call.request.params["value"]?.stringValue ?? "")
            },
            storage("clear", engine: engine) { _, area in .clear(area) },
        ]
    }

    private func storage(_ name: String, engine: any BrowserPageEngine,
                         _ make: @escaping @Sendable (ControlCall, BrowserPageScripts.StorageArea) throws -> BrowserPageScripts.StorageOperation) -> ControlMethod {
        .async("browser.page.storage.\(name)") { call in
            let tab = try Self.tab(call)
            let area: BrowserPageScripts.StorageArea = call.request.params["type"]?.stringValue == "session" ? .session : .local
            let operation = try make(call, area)
            let value = try await Self.run(engine, .evaluate(BrowserPageScripts.storage(operation)), tab)["value"] ?? .null
            if let error = value["error"]?.stringValue {
                throw ControlError(code: "invalid_state", message: error)
            }
            var result = Self.base(tab)
            result["type"] = .string(area.rawValue)
            let payload = value["value"] ?? .null
            for key in ["key", "value", "cleared"] where payload[key] != nil { result[key] = payload[key] }
            return .object(result)
        }
    }

    static func cookies(_ engine: any BrowserPageEngine, _ tab: Tab) async throws -> [BrowserPageCookie] {
        guard case .array(let list)? = try await run(engine, .cookies(.list), tab)["cookies"] else { return [] }
        return list.compactMap(BrowserPageCookie.init(json:))
    }

    /// One cookie from `name`, `value`, … or several from `cookies: [{…}]`.
    /// The domain comes from `url`, else `domain`, else the tab's page; a
    /// cookie without a leading-dot domain is host-only.
    static func cookiesToSet(_ call: ControlCall, tab: Tab) throws -> [BrowserPageCookie] {
        let params = call.request.params
        let entries: [JSONValue]
        if case .array(let list)? = params["cookies"] { entries = list } else { entries = [.object(params)] }
        let missing = ControlError.invalidParams(ControlStrings.text("control.error.cookiePayload",
                                                                     "Each cookie needs a name and a value, and a url, a domain or a tab with a page"))
        guard !entries.isEmpty else { throw missing }
        return try entries.map { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty, let value = entry["value"]?.stringValue else { throw missing }
            let url = entry["url"]?.stringValue.flatMap(URL.init(string:))
            guard let domain = url?.host ?? entry["domain"]?.stringValue ?? tab.url.flatMap(URL.init(string:))?.host, !domain.isEmpty else {
                throw missing
            }
            return BrowserPageCookie(name: name, value: value, domain: domain, path: entry["path"]?.stringValue ?? "/",
                                     expires: entry["expires"]?.doubleValue, secure: entry["secure"]?.boolValue ?? false,
                                     httpOnly: entry["http_only"]?.boolValue ?? entry["httpOnly"]?.boolValue ?? false)
        }
    }

    /// The old CLI's cookie filters. Listing: `name` exact, `domain` a
    /// substring, `path` exact. Clearing: `name` exact, `url` the cookies a
    /// request there carries, `domain` that domain or a subdomain, `path` exact.
    struct CookieFilter {
        var name: String?
        var url: URL?
        var domain: String?
        var path: String?

        init(_ params: [String: JSONValue]) {
            func text(_ key: String) -> String? { params[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
            name = text("name")
            url = text("url").flatMap(URL.init(string:))
            domain = text("domain")
            path = text("path")
        }

        var hasScope: Bool { name != nil || url != nil || domain != nil || path != nil }

        func listed(_ cookie: BrowserPageCookie) -> Bool {
            (name.map { cookie.name == $0 } ?? true)
                && (domain.map { cookie.domain.localizedCaseInsensitiveContains($0) } ?? true)
                && (path.map { cookie.path == $0 } ?? true)
        }

        func cleared(_ cookie: BrowserPageCookie, now: Date) -> Bool {
            (name.map { cookie.name == $0 } ?? true)
                && (url.map { cookie.isSent(to: $0, now: now) } ?? true)
                && (domain.map { cookie.isIn(domain: $0) } ?? true)
                && (path.map { cookie.path == $0 } ?? true)
        }
    }
}
