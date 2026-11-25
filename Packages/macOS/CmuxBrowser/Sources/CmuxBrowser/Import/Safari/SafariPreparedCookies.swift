public import Foundation

/// The cookies a Safari import will write, from ``SafariCookieImportPreparation``.
public struct SafariPreparedCookies {
    /// Live cookies that passed the domain filters, ready for a cookie store.
    public let cookies: [HTTPCookie]
    /// Cookies that passed the domain filters but had already expired.
    public let expiredCount: Int

    /// Creates a result; ``SafariCookieImportPreparation`` is the normal producer.
    public init(cookies: [HTTPCookie], expiredCount: Int) {
        self.cookies = cookies
        self.expiredCount = expiredCount
    }
}
