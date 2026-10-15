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
