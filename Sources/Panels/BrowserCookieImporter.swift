import Foundation
import WebKit

/// Parses and imports browser cookies from external files into WKHTTPCookieStore.
///
/// Supported export formats:
/// - **Cookie-Editor JSON** — exported from the Cookie-Editor browser extension
///   for Firefox/Chrome/Edge. Array of cookie objects.
/// - **Netscape/Mozilla text** — the classic tab-separated format used by curl,
///   wget, and most browser cookie exporters.
enum BrowserCookieImporter {
    struct ImportResult {
        let imported: Int
        let skipped: Int
    }

    enum ParseError: LocalizedError {
        case unrecognizedFormat

        var errorDescription: String? {
            String(
                localized: "browser.cookieImport.error.unrecognizedFormat",
                defaultValue: "Unrecognized cookie file format. Export cookies using the Cookie-Editor extension (JSON) or a Netscape-format exporter."
            )
        }
    }

    // MARK: - Public API

    struct ParseResult {
        let cookies: [HTTPCookie]
        let skipped: Int
    }

    /// Parse cookies from a file's raw data. Tries JSON first, then Netscape text.
    /// Returns both the valid cookies and a count of entries that could not be parsed.
    static func parseCookies(from data: Data) throws -> ParseResult {
        if let result = parseAsJSON(data), !result.cookies.isEmpty || result.skipped > 0 {
            return result
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let result = parseNetscapeFormat(text)
        if !result.cookies.isEmpty || result.skipped > 0 { return result }
        throw ParseError.unrecognizedFormat
    }

    /// Write cookies into the given store. Completion is called on the main queue.
    static func importCookies(
        _ cookies: [HTTPCookie],
        into store: WKHTTPCookieStore,
        skipped: Int = 0,
        completion: @escaping (ImportResult) -> Void
    ) {
        guard !cookies.isEmpty else {
            DispatchQueue.main.async { completion(ImportResult(imported: 0, skipped: skipped)) }
            return
        }
        // WKHTTPCookieStore.setCookie always calls its completion handler — it
        // provides no success/failure signal — so every cookie we submit counts
        // as imported. Track the total before entering any callbacks to avoid
        // any risk of unsynchronized mutation.
        let total = cookies.count
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            completion(ImportResult(imported: total, skipped: skipped))
        }
    }

    // MARK: - Cookie-Editor JSON

    /// Cookie-Editor format: JSON array of objects with name, value, domain, path,
    /// secure, httpOnly, expirationDate, sameSite fields.
    private static func parseAsJSON(_ data: Data) -> ParseResult? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var cookies: [HTTPCookie] = []
        var skipped = 0
        for obj in array {
            if let cookie = cookieFromJSONObject(obj) {
                cookies.append(cookie)
            } else {
                skipped += 1
            }
        }
        return ParseResult(cookies: cookies, skipped: skipped)
    }

    private static func cookieFromJSONObject(_ raw: [String: Any]) -> HTTPCookie? {
        guard let name = raw["name"] as? String,
              let value = raw["value"] as? String else { return nil }

        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: (raw["path"] as? String) ?? "/",
        ]

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }

        // Cookie-Editor uses "expirationDate"; some exporters use "expires".
        let expiryRaw = raw["expirationDate"] ?? raw["expires"]
        if let ts = expiryRaw as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: ts)
        } else if let ts = expiryRaw as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(ts))
        } else if let str = expiryRaw as? String {
            // Some exporters encode the date as an ISO 8601 string.
            if let date = ISO8601DateFormatter().date(from: str) {
                props[.expires] = date
            }
        }

        if let sameSite = raw["sameSite"] as? String {
            switch sameSite.lowercased() {
            case "strict":
                props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            case "lax":
                props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            default:
                break
            }
        }

        return HTTPCookie(properties: props)
    }

    // MARK: - Netscape format

    /// Classic Netscape/Mozilla cookie file format (used by curl, wget, etc.).
    /// Non-comment lines contain 7 tab-separated fields:
    ///   domain  includeSubdomains  path  secureFlag  expiry  name  value
    ///
    /// Lines prefixed with `#HttpOnly_` are HttpOnly cookies, not comments.
    /// The prefix is stripped from the domain field before parsing.
    private static func parseNetscapeFormat(_ text: String) -> ParseResult {
        let httpOnlyPrefix = "#HttpOnly_"
        var cookies: [HTTPCookie] = []
        var skipped = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Lines starting with # are comments, EXCEPT for #HttpOnly_ which
            // encodes the HttpOnly flag as a domain prefix in the Netscape format.
            let isHttpOnly = trimmed.hasPrefix(httpOnlyPrefix)
            if trimmed.hasPrefix("#") && !isHttpOnly { continue }
            let content = isHttpOnly ? String(trimmed.dropFirst(httpOnlyPrefix.count)) : trimmed
            let fields = content.components(separatedBy: "\t")
            guard fields.count >= 7 else { skipped += 1; continue }
            let domain  = fields[0]
            let path    = fields[2]
            let secure  = fields[3].uppercased() == "TRUE"
            let name    = fields[5]
            let value   = fields[6]
            guard !name.isEmpty else { skipped += 1; continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure { props[.secure] = "TRUE" }
            if isHttpOnly { props[.comment] = "HttpOnly" }
            if let ts = TimeInterval(fields[4]), ts > 0 {
                props[.expires] = Date(timeIntervalSince1970: ts)
            }
            if let cookie = HTTPCookie(properties: props) {
                cookies.append(cookie)
            } else {
                skipped += 1
            }
        }
        return ParseResult(cookies: cookies, skipped: skipped)
    }
}
