import Darwin
import Foundation

/// A Chromium main-frame failure as a load error. Chromium's own page shows
/// for it (`CEFTab.loadError`); cmux's page shows this text only for a
/// failure whose Chromium page is empty, and its certificate warning in an
/// agent-driven tab: a sentence a person can act on, then Chromium's error
/// name (ERR_NAME_NOT_RESOLVED), as Chrome's page does.
nonisolated struct ChromiumNetError {
    static let domain = "net"
    /// ERR_BLOCKED_BY_ADMINISTRATOR: an organization's URLBlocklist policy refused the page.
    static let blockedByAdministrator = -22
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
        case Self.blockedByAdministrator: Strings.netErrorBlockedByAdministrator
        case Self.certificateCodes: Strings.netErrorCertificate
        default: Strings.netErrorGeneric
        }
    }

    func loadError(failingURL: URL?, engineShowsPage: Bool) -> BrowserLoadError {
        let message = Self.certificateCodes.contains(code) ? "\(sentence) (\(name))" : "\(sentence)\n\(name)"
        var error = BrowserLoadError(domain: Self.domain, code: code, message: message, failingURL: failingURL)
        error.engineShowsPage = engineShowsPage
        return error
    }

    /// Proceed on cmux's certificate warning page (an agent-driven tab:
    /// `OnCertificateError` cancels the load there, so cmux shows its own
    /// page; other tabs show Chromium's interstitial). This
    /// answers the browser's next certificate error on `host` before the
    /// page loads again: continued for an overridable error on an IP
    /// address, which HSTS never covers (RFC 6797), otherwise left to
    /// Chromium's interstitial, which knows the host's HSTS state (the shim
    /// then marks that load error `chromiumInterstitial`). Then loads the
    /// page again. Both are one-way and go in this order, so Chromium has the
    /// answer before the load's error, as Chrome's interstitial proceeds: it
    /// allows the certificate for the host (`SSLHostStateDelegate::AllowCert`,
    /// content/public/browser/ssl_host_state_delegate.h), then reloads.
    @MainActor
    static func proceed(on tab: CEFTab) {
        guard let browser = tab.browserID, let shim = tab.runtime.shim, let error = tab.state.loadError,
              let url = error.failingURL, let host = url.host() else { return }
        allowNextError(code: error.code, host: host, browser: browser, shim: shim)
        tab.load(url)
    }

    @MainActor
    private static func allowNextError(code: Int, host: String, browser: Int32, shim: CEFShimLibrary) {
        var v4 = in_addr(), v6 = in6_addr()
        // SAFETY: inet_pton writes at most one in_addr into `v4` for AF_INET and one in6_addr into `v6` for AF_INET6,
        // during the call; Swift passes `host` as a NUL-terminated copy.
        let isV4 = unsafe inet_pton(AF_INET, host, &v4) == 1
        let isV6 = unsafe inet_pton(AF_INET6, host, &v6) == 1
        let isAddress = isV4 || isV6
        let chromiumDecides = !(isAddress && overridableCertificateCodes.contains(code))
        // Chromium's host keeps an IPv6 address in brackets.
        let chromiumHost = host.contains(":") ? "[\(host)]" : host
        _ = shim.certificateProceed(browser, chromiumHost, Int32(code), chromiumDecides ? 1 : 0)
    }
}
