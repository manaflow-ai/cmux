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

    /// Parse cookies from a file's raw data. Tries JSON first, then Netscape text.
    static func parseCookies(from data: Data) throws -> [HTTPCookie] {
        if let cookies = parseAsJSON(data), !cookies.isEmpty {
            return cookies
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let cookies = parseNetscapeFormat(text)
        if !cookies.isEmpty { return cookies }
        throw ParseError.unrecognizedFormat
    }

    /// Write cookies into the given store. Completion is called on the main queue.
    static func importCookies(
        _ cookies: [HTTPCookie],
        into store: WKHTTPCookieStore,
        completion: @escaping (ImportResult) -> Void
    ) {
        guard !cookies.isEmpty else {
            DispatchQueue.main.async { completion(ImportResult(imported: 0, skipped: 0)) }
            return
        }
        let group = DispatchGroup()
        var imported = 0
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) {
                imported += 1
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(ImportResult(imported: imported, skipped: cookies.count - imported))
        }
    }

    // MARK: - Cookie-Editor JSON

    /// Cookie-Editor format: JSON array of objects with name, value, domain, path,
    /// secure, httpOnly, expirationDate, sameSite fields.
    private static func parseAsJSON(_ data: Data) -> [HTTPCookie]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return array.compactMap { cookieFromJSONObject($0) }
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
    private static func parseNetscapeFormat(_ text: String) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.components(separatedBy: "\t")
            guard fields.count >= 7 else { continue }
            let domain  = fields[0]
            let path    = fields[2]
            let secure  = fields[3].uppercased() == "TRUE"
            let name    = fields[5]
            let value   = fields[6]
            guard !name.isEmpty else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
            ]
            if secure { props[.secure] = "TRUE" }
            if let ts = TimeInterval(fields[4]), ts > 0 {
                props[.expires] = Date(timeIntervalSince1970: ts)
            }
            if let cookie = HTTPCookie(properties: props) {
                cookies.append(cookie)
            }
        }
        return cookies
    }
}
