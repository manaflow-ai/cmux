public import Foundation

private let browserCookieGMT = TimeZone(secondsFromGMT: 0)!
private let browserCookieWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let browserCookieMonthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

private func browserCookieURL(scheme: String, host: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    components.path = "/"
    return components.url
}

private func browserCookieNormalizedDomain(_ domain: String) -> String {
    domain
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
}

private func browserCookieSameDomainScope(_ lhs: String, _ rhs: String) -> Bool {
    browserCookieNormalizedDomain(lhs) == browserCookieNormalizedDomain(rhs) &&
        lhs.hasPrefix(".") == rhs.hasPrefix(".")
}

private func browserCookieHTTPDateString(_ date: Date) -> String? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = browserCookieGMT
    let components = calendar.dateComponents(
        [.weekday, .day, .month, .year, .hour, .minute, .second],
        from: date
    )
    guard let weekday = components.weekday,
          let day = components.day,
          let month = components.month,
          let year = components.year,
          let hour = components.hour,
          let minute = components.minute,
          let second = components.second,
          browserCookieWeekdayNames.indices.contains(weekday - 1),
          browserCookieMonthNames.indices.contains(month - 1) else {
        return nil
    }

    return "\(browserCookieWeekdayNames[weekday - 1]), \(browserCookieTwoDigits(day)) \(browserCookieMonthNames[month - 1]) \(year) " +
        "\(browserCookieTwoDigits(hour)):\(browserCookieTwoDigits(minute)):\(browserCookieTwoDigits(second)) GMT"
}

private func browserCookieTwoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : String(value)
}

/// Builds browser cookies from the fields accepted by browser cookie automation.
public struct BrowserCookieBuilder: Sendable {
    /// Creates a stateless browser cookie builder.
    public init() {}

    /// Builds a cookie from its browser automation fields.
    ///
    /// - Parameters:
    ///   - name: The cookie name.
    ///   - value: The cookie value.
    ///   - originURL: The URL that supplies cookie defaults when `domain` is absent.
    ///   - domain: The cookie domain, when one was supplied by the caller.
    ///   - path: The cookie path.
    ///   - secure: Whether the cookie is restricted to secure transports.
    ///   - expires: The cookie expiration date, or `nil` for a session cookie.
    ///   - httpOnly: Whether the cookie should be hidden from page JavaScript.
    /// - Returns: The constructed cookie, or `nil` when the fields are invalid.
    public func makeCookie(
        name: String,
        value: String,
        originURL: URL?,
        domain: String?,
        path: String,
        secure: Bool,
        expires: Date?,
        httpOnly: Bool
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
        ]
        if let originURL {
            properties[.originURL] = originURL
        }
        if let domain {
            properties[.domain] = domain
        }
        properties[.path] = path
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }

        guard let cookie = HTTPCookie(properties: properties) else {
            return nil
        }
        guard httpOnly else {
            return cookie
        }

        guard let responseURL = responseURL(for: cookie, originURL: originURL),
              var setCookieHeader = setCookieHeader(for: cookie, includeDomain: cookie.domain.hasPrefix(".")) else {
            return nil
        }
        setCookieHeader += "; HttpOnly"

        let parsedCookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookieHeader],
            for: responseURL
        )
        guard parsedCookies.count == 1,
              let parsedCookie = parsedCookies.first,
              parsedCookie.name == cookie.name,
              parsedCookie.value == cookie.value,
              browserCookieSameDomainScope(parsedCookie.domain, cookie.domain),
              parsedCookie.path == cookie.path,
              parsedCookie.isSecure == cookie.isSecure,
              parsedCookie.isHTTPOnly else {
            return nil
        }
        return parsedCookie
    }

    private func setCookieHeader(for cookie: HTTPCookie, includeDomain: Bool) -> String? {
        var header = "\(cookie.name)=\(cookie.value)"
        if includeDomain, !cookie.domain.isEmpty {
            header += "; Domain=\(cookie.domain)"
        }
        header += "; Path=\(cookie.path)"
        if cookie.isSecure {
            header += "; Secure"
        }
        if let expiresDate = cookie.expiresDate {
            guard let httpDate = browserCookieHTTPDateString(expiresDate) else {
                return nil
            }
            header += "; Expires=\(httpDate)"
        }
        return header
    }

    private func responseURL(for cookie: HTTPCookie, originURL: URL?) -> URL? {
        let candidate = originURL ?? browserCookieURL(scheme: cookie.isSecure ? "https" : "http", host: cookie.domain)
        guard var components = candidate.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return browserCookieURL(scheme: cookie.isSecure ? "https" : "http", host: cookie.domain)
        }
        // Foundation rejects a Secure Set-Cookie header parsed against an HTTP
        // URL, even though the cookie itself remains valid for HTTPS requests.
        if cookie.isSecure {
            components.scheme = "https"
        }
        return components.url
    }

}
