package import Foundation

/// The Stripe mode of a checkout or portal URL: Checkout sessions are
/// `cs_test_…` / `cs_live_…`, portal sessions `/p/session/test_…` / `live_…`.
/// Anything else (a cmux.com page) is unknown.
package nonisolated enum StripeCheckoutMode: String, Sendable, Equatable {
    case test
    case live
    case unknown

    package init(url: URL) {
        let host = url.host?.lowercased() ?? ""
        guard host == "stripe.com" || host.hasSuffix(".stripe.com") else { self = .unknown; return }
        let last = url.path.split(separator: "/").last.map(String.init) ?? ""
        if last.hasPrefix("cs_test_") || last.hasPrefix("test_") {
            self = .test
        } else if last.hasPrefix("cs_live_") || last.hasPrefix("live_") {
            self = .live
        } else {
            self = .unknown
        }
    }
}
