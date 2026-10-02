public import Foundation

/// Foundation cookies for a WebKit store. `HTTPCookiePropertyKey` has no
/// HttpOnly key, so an HttpOnly cookie is parsed from a `Set-Cookie`
/// header, as the old app's `BrowserCookieBuilder` did (#10530). Parsing
/// caps its expiry at 400 days from now (RFC 6265bis), as Chromium does.
nonisolated extension BrowserCookie {
    /// Nil when a field cannot be a cookie (or HttpOnly did not survive).
    public var httpCookie: HTTPCookie? {
        guard Self.isHeaderSafe(name), Self.isHeaderSafe(value), Self.isHeaderSafe(domain), Self.isHeaderSafe(path) else { return nil }
        let host = domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, let url = URL(string: (secure ? "https://" : "http://") + host + "/") else { return nil }
        guard httpOnly else {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .originURL: url]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
        var header = "\(name)=\(value); Path=\(path)"
        if domain.hasPrefix(".") { header += "; Domain=\(domain)" }
        if secure { header += "; Secure" }
        if let expires { header += "; Expires=" + Self.httpDate(expires) }
        header += "; HttpOnly"
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
        guard parsed.count == 1, let cookie = parsed.first, cookie.isHTTPOnly, cookie.name == name, cookie.value == value,
              cookie.path == path, cookie.isSecure == secure else { return nil }
        return cookie
    }

    /// No `;`, CR, LF or other control characters, which would end or split the header.
    public static func isHeaderSafe(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value == 0x3B || $0.value < 0x20 || $0.value == 0x7F }
    }

    /// An RFC 1123 date (a formatter is not Sendable, so one per call).
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
