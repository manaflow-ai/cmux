public import Foundation

/// The category a failed browser navigation falls into, classified purely from
/// the underlying `NSError`'s domain and code.
///
/// The classification is a stateless transform over `(NSError.domain,
/// NSError.code)`, never any live WebKit or delegate state. The app-side
/// navigation delegate extracts those two primitives, calls
/// ``classify(domain:code:)``, maps the resulting kind to localized title and
/// message strings (`String(localized:)` stays app-side so the Japanese binding
/// is preserved), and renders the page with ``BrowserNavigationErrorPage``.
public enum BrowserNavigationErrorKind: Sendable, Equatable {
    /// The host refused or could not be reached (connect failure, host not
    /// found, or timeout).
    case cantReach
    /// The device has no usable network connection.
    case noInternet
    /// The TLS connection or server certificate could not be trusted.
    case insecure
    /// Any other failure; the app-side witness surfaces
    /// `error.localizedDescription` as the message.
    case cantOpen

    /// Classifies a navigation failure from its `NSError` domain and code.
    ///
    /// The branch grouping matches the app-side navigation delegate exactly: the
    /// `NSURLErrorDomain` connect/host/timeout codes map to ``cantReach``, the
    /// not-connected/connection-lost codes to ``noInternet``, the
    /// secure-connection and server-certificate codes to ``insecure``, and every
    /// other domain/code pair to ``cantOpen``.
    ///
    /// - Parameters:
    ///   - domain: The failing error's `NSError.domain`.
    ///   - code: The failing error's `NSError.code`.
    /// - Returns: The matching error kind.
    public static func classify(domain: String, code: Int) -> BrowserNavigationErrorKind {
        switch (domain, code) {
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            return .cantReach
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return .noInternet
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            return .insecure
        default:
            return .cantOpen
        }
    }
}
