public import Foundation

/// A Chromium main-frame load failure (`CefLoadHandler::OnLoadError`).
///
/// Chromium shows its own error page for these at once ("This site can't be
/// reached", "Your connection is not private" with Advanced and Proceed), so a
/// Chromium panel never covers it with cmux's WebKit error page. cmux shows a
/// page of its own only when Chromium's page is empty, with a sentence a
/// person can act on and Chromium's error name, as Chrome's page does.
///
/// Reference: cmux Next `CmuxNextBrowser/CEF/ChromiumNetError.swift` and the
/// `chromium-error-pages-first` / `chromium-error-page-new-tab` release notes.
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
        /// cmux's error view with `message`: Chromium's page is empty.
        case cmuxPage(message: String)
    }

    /// The presentation, given whether Chromium rendered its own error page.
    public func presentation(chromiumShowsPage: Bool) -> Presentation {
        if code == Self.abortedCode { return .nothing }
        if chromiumShowsPage { return .chromiumPage }
        return .cmuxPage(message: message)
    }

    /// Chromium's error name without the `net::` prefix, "ERR_NAME_NOT_RESOLVED".
    public var name: String {
        let name = text.hasPrefix("net::") ? String(text.dropFirst("net::".count)) : text
        return name.isEmpty ? "net::\(code)" : name
    }

    /// Whether the failure is a certificate error.
    public var isCertificateError: Bool { Self.certificateCodes.contains(code) }

    /// The sentence and the error name, for cmux's error view.
    public var message: String {
        isCertificateError ? "\(sentence) (\(name))" : "\(sentence)\n\(name)"
    }

    /// A sentence a person can act on.
    public var sentence: String {
        switch code {
        case -105, -137:
            String(localized: "browser.chromium.netError.notFound",
                   defaultValue: "The server\u{2019}s address could not be found.", bundle: .module)
        case -102:
            String(localized: "browser.chromium.netError.refused",
                   defaultValue: "The server refused the connection.", bundle: .module)
        case -7, -118:
            String(localized: "browser.chromium.netError.timedOut",
                   defaultValue: "The server took too long to respond.", bundle: .module)
        case -106:
            String(localized: "browser.chromium.netError.offline",
                   defaultValue: "You\u{2019}re not connected to the internet.", bundle: .module)
        case Self.certificateCodes:
            String(localized: "browser.chromium.netError.certificate",
                   defaultValue: "Its certificate is not valid.", bundle: .module)
        default:
            String(localized: "browser.chromium.netError.generic",
                   defaultValue: "The page could not be loaded.", bundle: .module)
        }
    }
}
