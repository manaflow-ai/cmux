import Foundation

/// Automation cookies (`browser.page.cookies.*`) in a CEF tab's profile,
/// kept out of `CEFTab` for its size; `BrowserTab.cookies`, `setCookie` and
/// `deleteCookies` call it. CEF's cookie visitor (Page Info) reports no
/// values, so these use the DevTools `Network` cookie methods, which act on
/// the same store.
@MainActor
struct CEFCookieStore {
    let tab: CEFTab

    func cookies() async throws -> [BrowserCookie] {
        guard let browserID = tab.browserID, !tab.isClosed else { throw BrowserTabError.closed }
        let json = try await tab.runtime.devTools(browserID, method: "Network.getAllCookies")
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

    func set(_ cookie: BrowserCookie) async throws {
        guard let browserID = tab.browserID, !tab.isClosed else { throw BrowserTabError.closed }
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
        _ = try await tab.runtime.devTools(browserID, method: "Network.setCookie", params: params)
    }

    func delete(_ cookies: [BrowserCookie]) async throws {
        guard let browserID = tab.browserID, !tab.isClosed else { throw BrowserTabError.closed }
        // An empty batch stays the no-op it was, rather than reading the runtime to do nothing.
        guard !cookies.isEmpty else { return }
        // `CEFTab.runtime` is `unowned`, so it is read once here and held for the whole batch:
        // re-reading it after a call would trap once the runtime's last owner went, which aborts
        // the process rather than failing one delete (see `CEFMediaBridge.run`).
        let runtime = tab.runtime
        for cookie in cookies {
            _ = try await runtime.devTools(browserID, method: "Network.deleteCookies",
                                           params: ["name": cookie.name, "domain": cookie.domain, "path": cookie.path])
        }
    }
}
