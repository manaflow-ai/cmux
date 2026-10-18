public import Foundation

/// Which cookies a driver `cookies.clear` call deletes.
///
/// Driven tabs use the user's browser profile, so a clear without a scope
/// would sign the user out of every site. The driver scopes the clear to the
/// site (registrable domain, ``BrowserReplPublicSuffixList``) of the tab
/// whose store it clears: the cookies on that domain and its subdomains. The
/// site comes from the tab, never from the caller, since the REPL's
/// JavaScript is untrusted. Playwright's `name`, `domain` and `path` filters
/// then narrow the selection by exact match. `all: true` selects every site
/// and is refused on a persistent profile; a data store that is not
/// persistent (a private tab's or the session's proxy store) holds nothing
/// of the user's, so it may be cleared whole.
public struct BrowserReplCookieClearScope: Equatable, Sendable {
    /// The registrable domain to clear, or `nil` for every site.
    public let site: String?
    public let name: String?
    public let domain: String?
    public let path: String?

    /// Why a `cookies.clear` call was refused.
    public struct Refusal: Error, Equatable, Sendable {
        public let message: String
    }

    /// Reads `{ all?, name?, domain?, path? }`; a `site` parameter is ignored.
    /// - Parameters:
    ///   - tabURL: The URL of the tab whose store is cleared.
    ///   - storeIsPersistent: Whether that store is a persistent profile the
    ///     user also browses with.
    /// - Throws: ``Refusal`` for `all: true` on a persistent store, and for a
    ///   tab with no http(s) site on a persistent store.
    public init(
        params: [String: Any],
        tabURL: URL?,
        storeIsPersistent: Bool,
        publicSuffixes: BrowserReplPublicSuffixList
    ) throws {
        if params["all"] as? Bool ?? false {
            if storeIsPersistent {
                throw Refusal(message: "cookies.clear: { all: true } would clear every site in the user's browser profile, which a session may not do; clear the current tab's site instead (a private tab's store, or one from session.configure({ proxy }), may be cleared whole)")
            }
            site = nil
        } else if let tabURL, let scheme = tabURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = BrowserReplHostName.host(of: tabURL) {
            site = publicSuffixes.site(of: host)
        } else if storeIsPersistent {
            throw Refusal(message: "cookies.clear: the tab (\(tabURL?.absoluteString ?? "none")) has no site to scope to; open the site first")
        } else {
            site = nil
        }
        name = Self.nonEmpty(params["name"])
        domain = Self.nonEmpty(params["domain"])
        path = Self.nonEmpty(params["path"])
    }

    /// Whether the cookie with these attributes is cleared.
    public func includes(name cookieName: String, domain cookieDomain: String, path cookiePath: String) -> Bool {
        if let site {
            let host = Self.bareDomain(cookieDomain)
            guard host == site || host.hasSuffix("." + site) else { return false }
        }
        if let name, cookieName != name { return false }
        if let domain, cookieDomain != domain { return false }
        if let path, cookiePath != path { return false }
        return true
    }

    private static func bareDomain(_ value: String) -> String {
        var host = value
        while host.hasPrefix(".") { host.removeFirst() }
        return BrowserReplHostName.normalize(host)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
