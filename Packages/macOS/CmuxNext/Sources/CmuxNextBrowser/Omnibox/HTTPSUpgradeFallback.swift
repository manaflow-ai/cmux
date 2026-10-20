import Foundation

/// Chrome's HTTPS-Upgrades fallback for typed addresses: a scheme-less
/// address the omnibar loads over https (`example.com`) that cannot connect
/// over https loads once over http, as Chrome's typed navigations do
/// (`TypedNavigationUpgradeThrottle`). Explicit `https://` and pages that
/// connected stay as they are; a host that does not resolve does not fall
/// back (http would not resolve either).
nonisolated struct HTTPSUpgradeFallback {
    /// The upgraded address the omnibar loaded, until it connects or fails.
    private(set) var pending: URL?
    /// The tab started loading since `pending` was set.
    private var sawLoad = false
    /// The tab's error when `pending` was set: an earlier failure, not this load's.
    private var earlierError: BrowserLoadError?

    /// The omnibar loads `url`, an https upgrade of typed text; `current`
    /// is the error the tab shows now (an earlier load's).
    mutating func expect(_ url: URL, current: BrowserLoadError? = nil) {
        pending = url
        sawLoad = false
        earlierError = current
    }

    /// Another commit, or editing started: nothing to fall back from.
    mutating func cancel() {
        pending = nil
    }

    /// The http address to load now, when `state` reports the upgraded
    /// load failed in a way http may fix. Clears once the load connected.
    mutating func observe(_ state: BrowserTabState) -> URL? {
        guard let pending else { return nil }
        if let error = state.loadError, sawLoad || error != earlierError,
           let failing = error.failingURL, Self.sameAddress(failing, pending) {
            self.pending = nil
            guard Self.fallsBack(error), var components = URLComponents(url: pending, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "http"
            if components.port == 443 { components.port = nil }
            return components.url
        }
        if state.isLoading {
            sawLoad = true
        } else if sawLoad, state.loadError == nil {
            // It connected (or went elsewhere): the https page stays.
            self.pending = nil
        }
        return nil
    }

    private static func sameAddress(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host()?.lowercased() == rhs.host()?.lowercased() && lhs.port == rhs.port
            && lhs.path(percentEncoded: true).trimmingSlash == rhs.path(percentEncoded: true).trimmingSlash
    }

    /// Failures of the TLS connection, not of the name: refused, reset,
    /// timed out, unreachable, and every TLS or certificate error.
    static func fallsBack(_ error: BrowserLoadError) -> Bool {
        if error.isCertificateError { return true }
        switch error.domain {
        case NSURLErrorDomain:
            return [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                    NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired,
                    NSURLErrorBadServerResponse].contains(error.code)
        case ChromiumNetError.domain:
            // net_error_list.h: connection (-100 to -199, without the name
            // errors -105 and -137 and being offline, -106) and certificate
            // (-200 to -299) errors.
            return (-199 ... -100).contains(error.code) && ![-105, -106, -137].contains(error.code)
                || ChromiumNetError.certificateCodes.contains(error.code) || error.code == -7
        default:
            return false
        }
    }
}

private nonisolated extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
