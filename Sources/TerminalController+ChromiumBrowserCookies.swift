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
                    if let domain,
                       let cookieDomain = cookie["domain"] as? String,
                       !cookieDomain.localizedCaseInsensitiveContains(domain) { return false }
                    if let path, cookie["path"] as? String != path { return false }
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
            "hostOnly": !domain.hasPrefix("."),
            "path": path,
            "secure": object["secure"]?.boolValue ?? false,
            "httpOnly": object["httpOnly"]?.boolValue ?? false,
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
