import CmuxBrowser
import Foundation

extension TerminalController {
    /// Reads Chromium's cookie jar through CDP. The compatibility WKWebView
    /// has a separate website-data store and must never be consulted for a
    /// Chromium-backed pane.
    nonisolated func v2GetChromiumCookies(
        browserPanel: BrowserPanel,
        name: String? = nil,
        domain: String? = nil,
        path: String? = nil,
        url: URL? = nil,
        timeout: TimeInterval = 5.0
    ) -> Result<[[String: Any]], any Error> {
        switch v2RunChromiumCommand(
            browserPanel: browserPanel,
            method: "Network.getAllCookies",
            timeout: timeout
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            guard case .object(let payload) = value,
                  case .array(let rawCookies)? = payload["cookies"] else {
                return .failure(CDPError.protocolError(ChromiumBrowserDiagnostic.malformedCookies.message))
            }
            let cookies = rawCookies.compactMap(Self.v2ChromiumCookieDictionary)
                .filter { cookie in
                    if let name, cookie["name"] as? String != name { return false }
                    if let domain {
                        guard let cookieDomain = cookie["domain"] as? String else { return false }
                        let filters = BrowserDataImporter.parseDomainFilters(domain)
                        guard !filters.isEmpty,
                              BrowserDataImporter.domainMatches(
                                host: cookieDomain,
                                filters: filters
                              ) else { return false }
                    }
                    if let path, cookie["path"] as? String != path { return false }
                    if let url {
                        guard let cookieDomain = cookie["domain"] as? String,
                              let host = url.host,
                              BrowserDataImporter.cookieDomainMatches(
                                cookieDomain: cookieDomain,
                                host: host
                              ),
                              BrowserDataImporter.cookiePathMatches(
                                cookiePath: cookie["path"] as? String ?? "/",
                                urlPath: url.path
                              ) else { return false }
                        if (cookie["secure"] as? Bool) == true,
                           url.scheme?.caseInsensitiveCompare("https") != .orderedSame {
                            return false
                        }
                    }
                    return true
                }
            return .success(cookies)
        }
    }

    nonisolated func v2SetChromiumCookies(
        browserPanel: BrowserPanel,
        cookieObjects: [[String: Any]],
        fallbackURL: URL?,
        timeout: TimeInterval = 5.0
    ) -> Result<Int, any Error> {
        let values = cookieObjects.compactMap {
            Self.v2ChromiumCookieValue($0, fallbackURL: fallbackURL)
        }
        guard values.count == cookieObjects.count, !values.isEmpty else {
            return .failure(CDPError.commandFailed(ChromiumBrowserDiagnostic.invalidCookiePayload.message))
        }
        switch v2RunChromiumCommand(
            browserPanel: browserPanel,
            method: "Network.setCookies",
            parameters: .object(["cookies": .array(values)]),
            timeout: timeout
        ) {
        case .success:
            return .success(values.count)
        case .failure(let error):
            return .failure(error)
        }
    }

    nonisolated func v2ClearChromiumCookies(
        browserPanel: BrowserPanel,
        all: Bool,
        name: String?,
        domain: String?,
        path: String?,
        url: URL?,
        timeout: TimeInterval = 5.0
    ) -> Result<Int, any Error> {
        let clearAll = all || (name == nil && domain == nil && path == nil && url == nil)
        if clearAll {
            let cookieCount: Int
            switch v2GetChromiumCookies(browserPanel: browserPanel, timeout: timeout) {
            case .success(let cookies):
                cookieCount = cookies.count
            case .failure(let error):
                return .failure(error)
            }
            switch v2RunChromiumCommand(
                browserPanel: browserPanel,
                method: "Network.clearBrowserCookies",
                timeout: timeout
            ) {
            case .success:
                return .success(cookieCount)
            case .failure(let error):
                return .failure(error)
            }
        }

        switch v2GetChromiumCookies(
            browserPanel: browserPanel,
            name: name,
            domain: domain,
            path: path,
            url: url,
            timeout: timeout
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let cookies):
            var removed = 0
            for cookie in cookies {
                guard let cookieName = cookie["name"] as? String,
                      let cookieDomain = cookie["domain"] as? String else { continue }
                var parameters: [String: CDPValue] = [
                    "name": .string(cookieName),
                    "domain": .string(cookieDomain),
                ]
                if let cookiePath = cookie["path"] as? String {
                    parameters["path"] = .string(cookiePath)
                }
                switch v2RunChromiumCommand(
                    browserPanel: browserPanel,
                    method: "Network.deleteCookies",
                    parameters: .object(parameters),
                    timeout: timeout
                ) {
                case .success:
                    removed += 1
                case .failure(let error):
                    return .failure(error)
                }
            }
            return .success(removed)
        }
    }

    private nonisolated static func v2ChromiumCookieDictionary(
        _ value: CDPValue
    ) -> [String: Any]? {
        guard case .object(let object) = value,
              let name = object["name"]?.stringValue,
              let value = object["value"]?.stringValue,
              let domain = object["domain"]?.stringValue,
              let path = object["path"]?.stringValue else { return nil }
        var result: [String: Any] = [
            "name": name,
            "value": value,
            "domain": domain,
            "path": path,
            "secure": object["secure"]?.boolValue ?? false,
            "http_only": object["httpOnly"]?.boolValue ?? false,
            "session_only": object["session"]?.boolValue ?? false,
        ]
        if let expires = object["expires"]?.doubleValue,
           expires > 0,
           let exactExpiration = Int(exactly: expires.rounded(.towardZero)) {
            result["expires"] = exactExpiration
        } else {
            result["expires"] = NSNull()
        }
        if let sameSite = object["sameSite"]?.stringValue {
            result["same_site"] = sameSite
        }
        if let priority = object["priority"]?.stringValue {
            result["priority"] = priority
        }
        return result
    }

    private nonisolated static func v2ChromiumCookieValue(
        _ raw: [String: Any],
        fallbackURL: URL?
    ) -> CDPValue? {
        guard let name = raw["name"] as? String, !name.isEmpty,
              let value = raw["value"] as? String else { return nil }
        var object: [String: CDPValue] = [
            "name": .string(name),
            "value": .string(value),
            "path": .string((raw["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"),
        ]
        if let url = raw["url"] as? String, !url.isEmpty {
            object["url"] = .string(url)
        } else if let domain = raw["domain"] as? String, !domain.isEmpty {
            object["domain"] = .string(domain)
        } else if let host = fallbackURL?.host {
            object["domain"] = .string(host)
        } else {
            return nil
        }
        if let secure = raw["secure"] as? Bool { object["secure"] = .bool(secure) }
        if let httpOnly = (raw["http_only"] as? Bool) ?? (raw["httpOnly"] as? Bool) {
            object["httpOnly"] = .bool(httpOnly)
        }
        if let sameSite = (raw["same_site"] as? String) ?? (raw["sameSite"] as? String) {
            object["sameSite"] = .string(sameSite)
        }
        if let priority = raw["priority"] as? String { object["priority"] = .string(priority) }
        if let expires = raw["expires"] as? NSNumber {
            object["expires"] = .number(expires.doubleValue)
        } else if let expires = raw["expires"] as? Double {
            object["expires"] = .number(expires)
        } else if let expires = raw["expires"] as? Int {
            object["expires"] = .number(Double(expires))
        }
        return .object(object)
    }
}

private extension CDPValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
