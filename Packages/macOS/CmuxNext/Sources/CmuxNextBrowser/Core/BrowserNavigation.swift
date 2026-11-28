public import AppKit
public import Foundation

/// A navigation attempt. Engines assign one per started navigation so that
/// late callbacks for a superseded navigation are ignored.
public nonisolated struct BrowserNavigationID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "nav#\(rawValue)" }
}

/// A load failure reported by an engine.
public nonisolated struct BrowserLoadError: Error, Hashable, Sendable {
    public var domain: String
    public var code: Int
    public var message: String
    public var failingURL: URL?
    /// The engine draws its own page for this failure, so the pane shows no
    /// cmux view over it: Chromium's net error pages and certificate
    /// interstitial in a Chromium tab (Lawrence 2026-10-13). WebKit draws
    /// none, so its tabs show cmux's pages; so does an agent-driven
    /// Chromium tab for a certificate error.
    public var engineShowsPage = false
    /// Loading the address again would send a form again or reload a form's result (the failed navigation was a
    /// POST, or the shown document came from one): a retry is the person's choice, never automatic (BR-R1).
    public var sentForm = false

    public init(domain: String, code: Int, message: String, failingURL: URL? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        self.failingURL = failingURL
    }

    public init(_ error: any Error) {
        let ns = error as NSError
        self.init(
            domain: ns.domain,
            code: ns.code,
            message: ns.localizedDescription,
            failingURL: ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        )
    }

    /// A TLS certificate the system does not trust (the interstitial with
    /// Go Back and Proceed): WebKit's URL errors, Chromium's ERR_CERT_* codes.
    public var isCertificateError: Bool {
        if domain == ChromiumNetError.domain { return ChromiumNetError.certificateCodes.contains(code) }
        return domain == NSURLErrorDomain && [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
        ].contains(code)
    }

    /// A failure of the network on the way to a reachable page (offline, timed out, the connection dropped or
    /// could not be made, the name did not resolve): loading the address again later is likely to work, so the error
    /// page reloads it by itself while it is in sight (Chrome's `NetErrorAutoReloader`), unless ``sentForm``.
    public var isTransientNetworkFailure: Bool {
        guard domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        ].contains(code)
    }

    /// True for failures that are not user-visible errors: a cancelled load
    /// (Stop, or a new navigation replacing this one) or WebKit's
    /// "frame load interrupted" when a response becomes a download.
    public var isBenignInterruption: Bool {
        (domain == NSURLErrorDomain && code == NSURLErrorCancelled)
            || (domain == "WebKitErrorDomain" && code == 102)
    }
}
