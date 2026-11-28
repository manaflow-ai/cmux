#if os(iOS)
import Foundation
import WebKit

/// The Mac's `site-data` frame (PROTOCOL.md, hq RFD 0089 "Shared sessions"): the
/// cookies and local storage of one browser tab's site, which the person handed
/// to this iPhone with Open on iPhone. hostd decides what is in it (the site only,
/// never incognito or the Agents profile, expiry capped at 24 hours); this only
/// puts it in the phone's web data store before the page's first load. Nothing
/// goes back to the Mac.
struct SiteDataHandOff: Decodable, Equatable {
    struct Cookie: Decodable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expiresMs: Int64?
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?
    }

    struct StorageArea: Decodable, Equatable {
        var origin: String
        var items: [[String]]
    }

    var v: Int
    var site: String
    var cookies: [Cookie]
    var localStorage: [StorageArea]

    static func decode(_ data: Data) -> SiteDataHandOff? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let handOff = try? decoder.decode(SiteDataHandOff.self, from: data), handOff.v == 1 else { return nil }
        return handOff
    }

    var httpCookies: [HTTPCookie] {
        cookies.compactMap { cookie in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
            ]
            if let ms = cookie.expiresMs { properties[.expires] = Date(timeIntervalSince1970: Double(ms) / 1000) }
            if cookie.secure { properties[.secure] = "TRUE" }
            if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch cookie.sameSite?.lowercased() {
            case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
            case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
            default: break
            }
            return HTTPCookie(properties: properties)
        }
    }

    /// A document-start script that fills each handed origin's `localStorage` once
    /// per tab (keys the page already has are kept).
    var storageScript: String? {
        let areas = localStorage.filter { !$0.items.isEmpty }
        guard !areas.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: Dictionary(
                  areas.map { ($0.origin, $0.items.filter { $0.count == 2 }) }, uniquingKeysWith: { a, _ in a }),
                                                       options: [.withoutEscapingSlashes, .sortedKeys]),
              let text = String(data: json, encoding: .utf8) else { return nil }
        return """
        (() => { try {
          const items = (\(text))[location.origin];
          if (!items || sessionStorage.getItem("__cmuxSiteData")) return;
          for (const [k, v] of items) { if (localStorage.getItem(k) === null) localStorage.setItem(k, v); }
          sessionStorage.setItem("__cmuxSiteData", "1");
        } catch (_) {} })();
        """
    }

    /// Puts it in `webView`'s data store; returns once the cookies are set.
    @MainActor
    func apply(to webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in httpCookies { await store.setCookie(cookie) }
        if let storageScript {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: storageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
}
#endif
