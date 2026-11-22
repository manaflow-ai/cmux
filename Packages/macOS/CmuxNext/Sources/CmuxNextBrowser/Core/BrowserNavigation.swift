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
    /// Go Back and Proceed).
    public var isCertificateError: Bool {
        domain == NSURLErrorDomain && [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
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
