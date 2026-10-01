import Foundation

/// Automation cookies (`browser.page.cookies.*`) in the tab's profile.
/// CEF's cookie visitor (Page Info) reports no values, so these use the
/// DevTools `Network` cookie methods, which act on the same store.
extension CEFTab {
    public func cookies() async throws -> [BrowserCookie] {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        let json = try await runtime.devTools(browserID, method: "Network.getAllCookies")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["cookies"] as? [[String: Any]] else { throw BrowserTabError.unsupported("Network.getAllCookies") }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, let domain = entry["domain"] as? String else { return nil }
            let session = entry["session"] as? Bool ?? true
            let expires = (entry["expires"] as? NSNumber)?.doubleValue
            return BrowserCookie(name: name, value: entry["value"] as? String ?? "", domain: domain, path: entry["path"] as? String ?? "/",
                                 expires: session ? nil : expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                                 secure: entry["secure"] as? Bool ?? false, httpOnly: entry["httpOnly"] as? Bool ?? false)
        }
    }

    public func setCookie(_ cookie: BrowserCookie) async throws {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        var params: [String: Any] = ["name": cookie.name, "value": cookie.value, "path": cookie.path,
                                     "secure": cookie.secure, "httpOnly": cookie.httpOnly]
        if cookie.domain.hasPrefix(".") {
            params["domain"] = cookie.domain
        } else {
            // A url without a domain makes a host-only cookie.
            params["url"] = "\(cookie.secure ? "https" : "http")://\(cookie.domain)\(cookie.path)"
        }
        if let expires = cookie.expires { params["expires"] = expires.timeIntervalSince1970 }
        // A refused cookie is a protocol error from devTools.
        _ = try await runtime.devTools(browserID, method: "Network.setCookie", params: params)
    }

    public func deleteCookies(_ cookies: [BrowserCookie]) async throws {
        guard let browserID, !isClosed else { throw BrowserTabError.closed }
        for cookie in cookies {
            _ = try await runtime.devTools(browserID, method: "Network.deleteCookies",
                                           params: ["name": cookie.name, "domain": cookie.domain, "path": cookie.path])
        }
    }
}
