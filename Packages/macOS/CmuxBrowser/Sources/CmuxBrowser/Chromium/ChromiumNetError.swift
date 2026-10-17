public import Foundation

/// A Chromium main-frame load failure (`CefLoadHandler::OnLoadError`).
///
/// Chromium shows its own error page for these at once ("This site can't be
/// reached", "Your connection is not private" with Advanced and Proceed), so a
/// Chromium panel never covers it with cmux's WebKit error page. cmux shows a
/// view of its own only when Chromium's page is empty: a title shared with
/// WebKit panels' error page, a sentence a person can act on, and Chromium's
/// error name on its own line, as Chrome's page does. The view owns the copy;
/// this type only classifies the failure.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/ChromiumNetError.swift` and the
/// `chromium-error-pages-first` / `chromium-error-page-new-tab` release notes;
/// Classic `BrowserErrorPageContent` for the titles.
public struct ChromiumNetError: Equatable, Sendable {
    /// `net::ERR_ABORTED`: the load was stopped (Stop, a new navigation, a
    /// download). Not a failure a person needs to see.
    public static let abortedCode = -3
    /// ERR_CERT_* (`net_error_list.h`: -200 to -299).
    public static let certificateCodes = -299 ... -200
    /// Certificate errors Chrome lets a person proceed past on any host
    /// that HSTS does not cover: common name, date, authority.
    public static let overridableCertificateCodes: Set<Int> = [-200, -201, -202]
    /// Net errors whose Chromium error page is empty (seen live in cmux Next,
    /// cx-zjcq): cmux's page shows for them, not a blank pane.
    public static let emptyChromiumPageCodes: Set<Int> = [
        -338, // ERR_INVALID_AUTH_CREDENTIALS
    ]

    /// Chromium's error code.
    public let code: Int
    /// Chromium's error text, "net::ERR_NAME_NOT_RESOLVED".
    public let text: String

    public init(code: Int, text: String) {
        self.code = code
        self.text = text
    }

    /// What a Chromium panel shows for this failure.
    public enum Presentation: Equatable, Sendable {
        /// Nothing: the load was aborted on purpose.
        case nothing
        /// Chromium's own error page, already in the page.
        case chromiumPage
        /// cmux's error view (`title`, `detail`, `name`): Chromium's page is empty.
        case cmuxPage
    }

    /// The title of cmux's error view, the same titles WebKit panels use.
    public enum Title: Equatable, Sendable {
        /// "Can't reach this page".
        case cantReach
        /// "No internet connection".
        case noInternet
        /// "Connection isn't secure".
        case insecure
        /// "Can't open this page".
        case cantOpen
    }

    /// The sentence under the title.
    public enum Detail: Equatable, Sendable {
        /// The host name does not resolve.
        case addressNotFound
        /// The server refused the connection.
        case refused
        /// The server did not answer in time.
        case timedOut
        /// The Mac is offline.
        case offline
        /// The site's certificate is invalid.
        case certificate
        /// Anything else.
        case generic
    }

    /// Whether Chromium draws its own page for this failure: its net error
    /// page for most failures, its certificate interstitial only when the
    /// shim left the decision to it (`interstitial`). The shim cancels a
    /// certificate error in an agent-driven tab, so only a person can
    /// proceed there, and a few errors leave Chromium's page empty.
    /// Reference: cmux Next `CEFTab+Events.swift` `loadError(code:text:url:chromiumInterstitial:)`.
    /// - Parameter interstitial: The shim's `chromiumInterstitial` flag of the load error.
    public func chromiumShowsPage(interstitial: Bool) -> Bool {
        interstitial || !(isCertificateError || Self.emptyChromiumPageCodes.contains(code))
    }

    /// How Proceed on cmux's certificate warning answers the browser's next
    /// certificate error on `host` (`cmux_shim_certificate_proceed`): an
    /// overridable error on an IP address, which HSTS never covers
    /// (RFC 6797), continues; any other is left to Chromium's interstitial,
    /// which knows the host's HSTS state.
    /// Reference: cmux Next `ChromiumNetError.proceed(on:)`.
    /// - Parameter host: The failed URL's host, without IPv6 brackets.
    public func certificateProceed(host: String) -> ChromiumCertificateProceed {
        var v4 = in_addr(), v6 = in6_addr()
        let isAddress = inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
        // Chromium's host keeps an IPv6 address in brackets.
        let chromiumHost = host.contains(":") ? "[\(host)]" : host
        return ChromiumCertificateProceed(
            host: chromiumHost,
            chromiumDecides: !(isAddress && Self.overridableCertificateCodes.contains(code))
        )
    }

    /// The presentation, given whether Chromium rendered its own error page.
    public func presentation(chromiumShowsPage: Bool) -> Presentation {
        if code == Self.abortedCode { return .nothing }
        return chromiumShowsPage ? .chromiumPage : .cmuxPage
    }

    /// Chromium's error name without the `net::` prefix, "ERR_NAME_NOT_RESOLVED".
    public var name: String {
        let name = text.hasPrefix("net::") ? String(text.dropFirst("net::".count)) : text
        return name.isEmpty ? "net::\(code)" : name
    }

    /// Whether the failure is a certificate error.
    public var isCertificateError: Bool { Self.certificateCodes.contains(code) }

    public var detail: Detail {
        switch code {
        case -105, -137: .addressNotFound
        case -102: .refused
        case -7, -118: .timedOut
        case -106: .offline
        case Self.certificateCodes: .certificate
        default: .generic
        }
    }

    public var title: Title {
        switch detail {
        case .addressNotFound, .refused, .timedOut: .cantReach
        case .offline: .noInternet
        case .certificate: .insecure
        case .generic: .cantOpen
        }
    }
}

/// Proceed on cmux's certificate warning, as the Chromium shim takes it.
public struct ChromiumCertificateProceed: Equatable, Sendable {
    /// The host as Chromium names it (an IPv6 address in brackets).
    public let host: String
    /// `true` leaves the decision to Chromium's interstitial; `false`
    /// continues past the error.
    public let chromiumDecides: Bool

    public init(host: String, chromiumDecides: Bool) {
        self.host = host
        self.chromiumDecides = chromiumDecides
    }
}
