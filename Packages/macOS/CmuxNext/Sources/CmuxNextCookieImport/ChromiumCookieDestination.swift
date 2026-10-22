public import CmuxNextBrowser
public import CmuxNextBrowserImport
import Foundation

/// Imported cookies go to the target profile's Chromium cookie jar
/// (`CEFEngine.importCookies`, CefCookieManager::SetCookie per cookie). A
/// target id that is not a browser profile goes to the default profile.
public struct ChromiumCookieDestination: CookieDestination {
    let write: @MainActor @Sendable ([ChromiumCookieWrite], BrowserProfileID) async throws -> ChromiumCookieWriteResult

    /// Creates the destination over `write` (the App's `CEFEngine.importCookies`).
    public init(write: @escaping @MainActor @Sendable ([ChromiumCookieWrite], BrowserProfileID) async throws -> ChromiumCookieWriteResult) {
        self.write = write
    }

    public func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
        let profile = BrowserProfileRecord.engineProfile(for: profileID) ?? .default
        let writes = cookies.compactMap(Self.write(for:))
        let result: ChromiumCookieWriteResult
        do {
            result = try await write(writes, profile)
        } catch is BrowserEngineError {
            throw CookieImportError.storeUnavailable
        }
        return CookieWriteResult(written: result.written, rejected: result.rejected + cookies.count - writes.count)
    }

    /// Writes each cookie again already expired: Chromium's cookie store first deletes the cookie
    /// with the same name, domain and path, then drops the expired one (CookieMonster::
    /// SetCanonicalCookie), so the profile no longer holds it, whatever value the site set since.
    public func removeCookies(_ cookies: [ImportedCookieIdentity], profileID: String) async throws -> Int {
        let profile = BrowserProfileRecord.engineProfile(for: profileID) ?? .default
        let writes = cookies.compactMap(Self.removal(for:))
        guard !writes.isEmpty else { return 0 }
        do {
            return try await write(writes, profile).written
        } catch is BrowserEngineError {
            throw CookieImportError.storeUnavailable
        }
    }

    /// The write that removes `cookie`: the import's own URL, domain and path rule, an empty
    /// value and an expiry in 1970. Nil when the cookie has no usable URL.
    public nonisolated static func removal(for cookie: ImportedCookieIdentity) -> ChromiumCookieWrite? {
        let stand = ImportedCookie(name: cookie.name, value: "", domain: cookie.domain, path: cookie.path, secure: cookie.secure,
                                   expires: Date(timeIntervalSince1970: 86_400))
        return write(for: stand)
    }

    /// Nil when the cookie has no usable URL (an empty or invalid domain).
    public nonisolated static func write(for cookie: ImportedCookie) -> ChromiumCookieWrite? {
        guard !cookie.host.isEmpty, let url = cookie.url else { return nil }
        let sameSite: ChromiumCookieWrite.SameSite = switch cookie.sameSite {
        case .unspecified: .unspecified
        case .none: .noRestriction
        case .lax: .lax
        case .strict: .strict
        }
        // CEF makes any non-empty domain a domain cookie. Preserve a source host-only cookie by
        // supplying only its URL, as CEFCookieStore.set does; a leading dot remains domain-scoped.
        let domain = cookie.domain.hasPrefix(".") ? cookie.domain : ""
        return ChromiumCookieWrite(url: url, name: cookie.name, value: cookie.value, domain: domain, path: cookie.path,
                                   secure: cookie.secure, httpOnly: cookie.httpOnly, sameSite: sameSite,
                                   expires: cookie.expires, created: cookie.created, lastAccess: cookie.lastAccess)
    }
}
