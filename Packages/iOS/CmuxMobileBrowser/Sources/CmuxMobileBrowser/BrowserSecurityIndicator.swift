public import Foundation

/// The address-bar security indicator for a browser URL.
public enum BrowserSecurityIndicator: Equatable, Sendable {
    /// An HTTPS page.
    case secure
    /// A public HTTP page.
    case insecure
    /// No indicator should be shown.
    case none

    /// Classify the security indicator for a URL.
    ///
    /// - Parameter url: The committed browser URL, or `nil` before navigation.
    public init(url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased() else {
            self = .none
            return
        }
        if scheme == "https" {
            self = .secure
            return
        }
        guard scheme == "http",
              let host = url.host(percentEncoded: false),
              !BrowserSecurityHostClassifier().isLocalOrPrivateHost(host)
        else {
            self = .none
            return
        }
        self = .insecure
    }

}
