import Darwin
import Foundation

/// A Chromium main-frame failure as cmux's error page shows it: a sentence
/// a person can act on, then Chromium's error name (ERR_NAME_NOT_RESOLVED),
/// as Chrome's own page does. Certificate errors (ERR_CERT_*) show cmux's
/// certificate warning, with the sentence as its reason.
nonisolated struct ChromiumNetError {
    static let domain = "net"
    /// ERR_CERT_* (net_error_list.h: -200 to -299).
    static let certificateCodes = -299 ... -200
    /// Certificate errors Chrome lets a person proceed past on any host
    /// that HSTS does not cover: common name, date, authority.
    static let overridableCertificateCodes: Set<Int> = [-200, -201, -202]

    let code: Int
    /// Chromium's error text, "net::ERR_NAME_NOT_RESOLVED".
    let text: String

    var name: String {
        let name = text.hasPrefix("net::") ? String(text.dropFirst("net::".count)) : text
        return name.isEmpty ? "net::\(code)" : name
    }

    var sentence: String {
        switch code {
        case -105, -137: Strings.netErrorNotFound
        case -102: Strings.netErrorRefused
        case -7, -118: Strings.netErrorTimedOut
        case -106: Strings.netErrorOffline
        case Self.certificateCodes: Strings.netErrorCertificate
        default: Strings.netErrorGeneric
        }
    }

    func loadError(failingURL: URL?) -> BrowserLoadError {
        let message = Self.certificateCodes.contains(code) ? "\(sentence) (\(name))" : "\(sentence)\n\(name)"
        return BrowserLoadError(domain: Self.domain, code: code, message: message, failingURL: failingURL)
    }

    /// Proceed on cmux's certificate warning page. Chromium failed the load
    /// (`OnCertificateError` cancels it) so cmux shows its own page; this
    /// answers the browser's next certificate error on `host` before the
    /// page loads again: continued for an overridable error on an IP
    /// address, which HSTS never covers (RFC 6797), otherwise left to
    /// Chromium's interstitial, which knows the host's HSTS state. Returns
    /// whether Chromium decides, or nil when the browser is gone.
    @MainActor
    static func proceed(code: Int, host: String, browser: Int32, shim: CEFShimLibrary?) -> Bool? {
        var v4 = in_addr(), v6 = in6_addr()
        let isAddress = inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
        let chromiumDecides = !(isAddress && overridableCertificateCodes.contains(code))
        // Chromium's host keeps an IPv6 address in brackets.
        let chromiumHost = host.contains(":") ? "[\(host)]" : host
        let answered = chromiumHost.withCString { shim?.certificateProceed(browser, $0, chromiumDecides ? 1 : 0) }
        return answered == 1 ? chromiumDecides : nil
    }
}
