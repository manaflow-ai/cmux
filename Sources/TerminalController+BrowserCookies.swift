import Foundation
import WebKit
import CmuxBrowser

extension TerminalController {
    nonisolated func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            // Preserve host-only scope so state save/load cannot widen a cookie.
            "hostOnly": !cookie.domain.hasPrefix("."),
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    nonisolated func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.getAllCookies { items in
                    finish(items)
                }
            }
        }
    }

    nonisolated func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.setCookie(cookie) {
                    finish(true)
                }
            }
        } ?? false
    }

    private nonisolated func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        v2AwaitCallback(timeout: timeout) { finish in
            v2MainSync {
                store.delete(cookie) {
                    finish(true)
                }
            }
        } ?? false
    }

    nonisolated func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        guard let name = raw["name"] as? String,
              let value = raw["value"] as? String else {
            return nil
        }

        let secure = v2Bool(raw, "secure") ?? false
        let serializedDomain = raw["domain"] as? String
        let hostOnly = v2Bool(raw, "hostOnly") == true
        let originURL: URL?
        if let urlString = raw["url"] as? String, let url = URL(string: urlString) {
            originURL = url
        } else if let serializedDomain {
            originURL = BrowserCookieBuilder().originURL(forHost: serializedDomain, secure: secure)
        } else {
            originURL = fallbackURL
        }
        let domain = hostOnly ? nil : serializedDomain
        let path = (raw["path"] as? String) ?? "/"
        let expires: Date?
        if let expiresValue = raw["expires"] as? TimeInterval {
            expires = Date(timeIntervalSince1970: expiresValue)
        } else if let expiresIntValue = raw["expires"] as? Int {
            expires = Date(timeIntervalSince1970: TimeInterval(expiresIntValue))
        } else {
            expires = nil
        }

        return BrowserCookieBuilder().makeCookie(
            name: name,
            value: value,
            originURL: originURL,
            domain: domain,
            path: path,
            secure: secure,
            expires: expires,
            httpOnly: v2Bool(raw, "httpOnly") ?? false
        )
    }

    nonisolated func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            if v2MainSync({ ctx.browserPanel.isChromiumBacked }) {
                switch v2GetChromiumCookies(
                    browserPanel: ctx.browserPanel,
                    name: v2String(params, "name"),
                    domain: v2String(params, "domain"),
                    path: v2String(params, "path"),
                    httpOnly: v2Bool(params, "httpOnly")
                ) {
                case .success(let cookies):
                    return .ok(v2BrowserPanelFields(ctx, adding: ["cookies": cookies]))
                case .failure(let error):
                    return .err(
                        code: "cdp_error",
                        message: v2ChromiumFailureMessage(operation: "cookie_read", error: error),
                        data: nil
                    )
                }
            }
            let store = v2MainSync {
                ctx.webView.configuration.websiteDataStore.httpCookieStore
            }
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let httpOnly = v2Bool(params, "httpOnly") {
                cookies = cookies.filter { $0.isHTTPOnly == httpOnly }
            }
            if let domain = v2String(params, "domain") {
                let filters = BrowserDataImporter.parseDomainFilters(domain)
                cookies = filters.isEmpty
                    ? []
                    : cookies.filter {
                        BrowserDataImporter.domainMatches(host: $0.domain, filters: filters)
                    }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["cookies": cookies.map(v2BrowserCookieDict)]))
        }
    }

    nonisolated func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let httpOnly = v2Bool(params, "httpOnly") { single["httpOnly"] = httpOnly }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty { cookieObjects = [single] }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }
            if v2MainSync({ ctx.browserPanel.isChromiumBacked }) {
                let fallbackURL = v2MainSync { ctx.browserPanel.currentURL }
                switch v2SetChromiumCookies(
                    browserPanel: ctx.browserPanel,
                    cookieObjects: cookieObjects,
                    fallbackURL: fallbackURL
                ) {
                case .success(let count):
                    return .ok(v2BrowserPanelFields(ctx, adding: ["set": count]))
                case .failure(let error):
                    return .err(
                        code: "cdp_error",
                        message: v2ChromiumFailureMessage(operation: "cookie_write", error: error),
                        data: nil
                    )
                }
            }
            let cookieContext = v2MainSync {
                (
                    store: ctx.webView.configuration.websiteDataStore.httpCookieStore,
                    fallbackURL: ctx.browserPanel.currentURL
                )
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: cookieContext.fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: nil)
                }
                if v2BrowserCookieStoreSet(cookieContext.store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: nil)
                }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["set": setCount]))
        }
    }

    nonisolated func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            let isChromium = v2MainSync { ctx.browserPanel.isChromiumBacked }
            let unsupportedSelectors = isChromium
                ? ["value", "url", "expires", "secure"].filter { params[$0] != nil }
                : []
            let clearRequiresScopeMessage = String(
                localized: "cli.browser.cookies.clearRequiresScope",
                defaultValue: "browser cookies clear requires exactly one of --all or a cookie scope"
            )
            let invalidFilterMessage = String(
                localized: "cli.browser.cookies.invalidFilter",
                defaultValue: "browser cookies clear received an invalid cookie filter"
            )
            let invalidURLMessage = String(
                localized: "cli.browser.cookies.invalidURL",
                defaultValue: "browser cookies clear --url requires a valid URL with a host"
            )
            let invalidExpiresMessage = String(
                localized: "cli.browser.cookies.invalidExpires",
                defaultValue: "browser cookies clear --expires must be an integer Unix timestamp"
            )
            guard unsupportedSelectors.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: invalidFilterMessage,
                    data: ["unsupported": unsupportedSelectors]
                )
            }
            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let path = v2String(params, "path")
            let value = v2String(params, "value")
            for key in ["name", "value", "domain", "path"] where
                v2HasNonNullParam(params, key) && v2String(params, key) == nil {
                return .err(code: "invalid_params", message: invalidFilterMessage, data: ["param": key])
            }
            let rawURL = v2String(params, "url")
            if v2HasNonNullParam(params, "url"), rawURL == nil {
                return .err(
                    code: "invalid_params",
                    message: invalidURLMessage,
                    data: ["param": "url"]
                )
            }
            let urlFilter: URL?
            if let rawURL {
                guard let parsedURL = URL(string: rawURL), parsedURL.host != nil else {
                    return .err(
                        code: "invalid_params",
                        message: invalidURLMessage,
                        data: ["param": "url"]
                    )
                }
                urlFilter = parsedURL
            } else {
                urlFilter = nil
            }
            let expires: Int?
            if v2HasNonNullParam(params, "expires") {
                guard let parsedExpires = v2Int(params, "expires") else {
                    return .err(
                        code: "invalid_params",
                        message: invalidExpiresMessage,
                        data: ["param": "expires"]
                    )
                }
                expires = parsedExpires
            } else {
                expires = nil
            }
            let secure: Bool?
            if v2HasNonNullParam(params, "secure") {
                guard let parsedSecure = v2Bool(params, "secure") else {
                    return .err(code: "invalid_params", message: invalidFilterMessage, data: ["param": "secure"])
                }
                secure = parsedSecure
            } else {
                secure = nil
            }
            let hasScope = name != nil || domain != nil || path != nil ||
                value != nil || urlFilter != nil || expires != nil || secure != nil
            let hasAllParameter = params["all"] != nil
            guard !hasAllParameter || v2Bool(params, "all") != nil else {
                return .err(
                    code: "invalid_params",
                    message: invalidFilterMessage,
                    data: ["param": "all"]
                )
            }
            let all = v2Bool(params, "all") == true
            guard !(all && hasScope) else {
                return .err(
                    code: "invalid_params",
                    message: clearRequiresScopeMessage,
                    data: nil
                )
            }
            guard !(hasAllParameter && !all && !hasScope) else {
                return .err(
                    code: "invalid_params",
                    message: clearRequiresScopeMessage,
                    data: ["param": "scope"]
                )
            }
            guard all || hasScope else {
                return .err(
                    code: "invalid_params",
                    message: clearRequiresScopeMessage,
                    data: ["param": "scope"]
                )
            }
            let clearAll = all
            if isChromium {
                switch v2ClearChromiumCookies(
                    browserPanel: ctx.browserPanel,
                    all: clearAll,
                    name: name,
                    domain: domain,
                    path: path,
                    url: urlFilter
                ) {
                case .success(let count):
                    return .ok(v2BrowserPanelFields(ctx, adding: ["cleared": count]))
                case .failure(let error):
                    return .err(
                        code: "cdp_error",
                        message: v2ChromiumFailureMessage(operation: "cookie_clear", error: error),
                        data: nil
                    )
                }
            }
            let store = v2MainSync {
                ctx.webView.configuration.websiteDataStore.httpCookieStore
            }
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain {
                    guard CmuxWebView.cookieDomainMatchesFilter(cookie.domain, filter: domain) else { return false }
                }
                if let path, cookie.path != path { return false }
                if let value, cookie.value != value { return false }
                if let expires,
                   cookie.expiresDate.map({ Int($0.timeIntervalSince1970) }) != expires { return false }
                if let secure, cookie.isSecure != secure { return false }
                if let url = urlFilter, !CmuxWebView.cookieMatchesURL(cookie, url: url) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok(v2BrowserPanelFields(ctx, adding: ["cleared": removed]))
        }
    }

}
