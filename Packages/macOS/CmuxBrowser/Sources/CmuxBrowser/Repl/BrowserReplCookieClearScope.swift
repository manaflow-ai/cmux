public import Foundation

/// Which cookies a driver `cookies.clear` call deletes.
///
/// Driven tabs use the user's browser profile, so a clear without a scope
/// would sign the user out of every site. The runtime scopes
/// `context.clearCookies()` like `session.storageState`: `site`, the
/// registrable domain of the current tab, selects the cookies on that domain
/// and its subdomains; `all: true` selects every site. Playwright's `name`,
/// `domain` and `path` filters then narrow the selection by exact match.
/// A data store that is not persistent (a private tab's or the session's
/// proxy store) holds nothing of the user's, so it may be cleared whole
/// without either.
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

    /// Reads `{ site?, all?, name?, domain?, path? }`.
    /// - Parameter storeIsPersistent: Whether the target data store is a
    ///   persistent profile the user also browses with.
    /// - Throws: ``Refusal`` when neither `site` nor `all: true` is given for
    ///   a persistent store.
    public init(params: [String: Any], storeIsPersistent: Bool) throws {
        let all = params["all"] as? Bool ?? false
        let site = (params["site"] as? String).map(Self.bareDomain).flatMap { $0.isEmpty ? nil : $0 }
        if !all, site == nil, storeIsPersistent {
            throw Refusal(message: "cookies.clear: pass { site } or { all: true }; the tab's profile is shared with the user")
        }
        self.site = all ? nil : site
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
        let lowered = value.lowercased()
        return lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
