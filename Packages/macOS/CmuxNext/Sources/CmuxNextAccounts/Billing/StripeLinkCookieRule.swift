package import Foundation

/// Whether a browser profile is signed in to Stripe Link
/// (plans/cmux-next/paid-product-DESIGN.md section 4): an unexpired cookie
/// on `link.com` or a subdomain. Only the domain and the expiry are read,
/// never a value. `checkout.stripe.com` and `m.stripe.com` do not count: any
/// Checkout page or Stripe.js site sets them, signed in or not.
package nonisolated struct StripeLinkCookieRule: Sendable {
    /// The registrable domain Link keeps its session on.
    package let domain = "link.com"

    /// Whether one cookie is a Link session cookie at `now`. `expires` nil is
    /// a session cookie (alive while the browser runs).
    package func matches(domain cookieDomain: String, expires: Date?, now: Date) -> Bool {
        if let expires, expires <= now { return false }
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Whether any of `cookies` (domain, expiry) is a Link session cookie.
    package func hasSession(_ cookies: [(String, Date?)], now: Date) -> Bool {
        cookies.contains { matches(domain: $0.0, expires: $0.1, now: now) }
    }

    /// Chromium's `expires_utc`: microseconds since 1601-01-01 UTC.
    package static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    package init() {
    }
}
