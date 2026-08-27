import Foundation
import WebKit
import CmuxBrowser

extension TerminalController {
    nonisolated func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
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
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    nonisolated func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanelContext(params: params) { ctx in
            if v2MainSync({ ctx.browserPanel.isChromiumBacked }) {
                switch v2GetChromiumCookies(
                    browserPanel: ctx.browserPanel,
                    name: v2String(params, "name"),
                    domain: v2String(params, "domain"),
                    path: v2String(params, "path")
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
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
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
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(cookieContext.store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
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
            guard unsupportedSelectors.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                    data: ["unsupported": unsupportedSelectors]
                )
            }
            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let path = v2String(params, "path")
            let value = v2String(params, "value")
            let rawURL = v2String(params, "url")
            let urlFilter: URL?
            if let rawURL {
                guard let parsedURL = URL(string: rawURL), parsedURL.host != nil else {
                    return .err(
                        code: "invalid_params",
                        message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                        data: ["url": rawURL]
                    )
                }
                urlFilter = parsedURL
            } else {
                urlFilter = nil
            }
            let expires = v2Int(params, "expires")
            let secure = v2Bool(params, "secure")
            let hasScope = name != nil || domain != nil || path != nil ||
                value != nil || urlFilter != nil || expires != nil || secure != nil
            let hasAllParameter = params["all"] != nil
            guard !hasAllParameter || v2Bool(params, "all") != nil else {
                return .err(
                    code: "invalid_params",
                    message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                    data: nil
                )
            }
            let all = v2Bool(params, "all") == true
            guard !(all && hasScope) else {
                return .err(
                    code: "invalid_params",
                    message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                    data: nil
                )
            }
            guard !(hasAllParameter && !all && !hasScope) else {
                return .err(
                    code: "invalid_params",
                    message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                    data: nil
                )
            }
            guard all || hasScope else {
                return .err(
                    code: "invalid_params",
                    message: ChromiumBrowserDiagnostic.invalidCookiePayload.message,
                    data: nil
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
                    let filters = BrowserDataImporter.parseDomainFilters(domain)
                    guard !filters.isEmpty,
                          BrowserDataImporter.domainMatches(host: cookie.domain, filters: filters) else {
                        return false
                    }
                }
                if let path, cookie.path != path { return false }
                if let value, cookie.value != value { return false }
                if let expires {
                    guard let cookieExpires = cookie.expiresDate else { return false }
                    guard Int(cookieExpires.timeIntervalSince1970.rounded(.towardZero)) == expires else {
                        return false
                    }
                }
                if let secure, cookie.isSecure != secure { return false }
                if let url = urlFilter, let host = url.host {
                    guard BrowserDataImporter.cookieDomainMatches(
                        cookieDomain: cookie.domain,
                        host: host
                    ) else {
                        return false
                    }
                    guard BrowserDataImporter.cookiePathMatches(
                        cookiePath: cookie.path,
                        urlPath: url.path
                    ) else { return false }
                }
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
