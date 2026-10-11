import CmuxNextBrowser
import CmuxNextBrowserImport
import Foundation

/// Imported cookies go to the target profile's Chromium cookie jar
/// (`CEFEngine.importCookies`, CefCookieManager::SetCookie per cookie). A
/// target id that is not a browser profile goes to the default profile.
struct AppCookieDestination: CookieDestination {
    let write: @MainActor @Sendable ([ChromiumCookieWrite], BrowserProfileID) async throws -> ChromiumCookieWriteResult

    func setCookies(_ cookies: [ImportedCookie], profileID: String) async throws -> CookieWriteResult {
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

    /// Nil when the cookie has no usable URL (an empty or invalid domain).
    nonisolated static func write(for cookie: ImportedCookie) -> ChromiumCookieWrite? {
        guard !cookie.host.isEmpty, let url = cookie.url else { return nil }
        let sameSite: ChromiumCookieWrite.SameSite = switch cookie.sameSite {
        case .unspecified: .unspecified
        case .none: .noRestriction
        case .lax: .lax
        case .strict: .strict
        }
        return ChromiumCookieWrite(url: url, name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                                   secure: cookie.secure, httpOnly: cookie.httpOnly, sameSite: sameSite,
                                   expires: cookie.expires, created: cookie.created, lastAccess: cookie.lastAccess)
    }
}
