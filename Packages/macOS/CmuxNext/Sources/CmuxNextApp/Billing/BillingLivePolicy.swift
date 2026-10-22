import Foundation

/// Whether cmux-next opens live-mode Stripe pages. Off until the user decides
/// to sell live plans from cmux-next (paid-product-DESIGN.md section 9): a
/// live session is then refused with `billing.live_off` and nothing opens.
/// Turning it on is a one-line change of ``shipped``.
nonisolated struct BillingLivePolicy: Sendable, Equatable {
    let liveCheckout: Bool

    /// The value this build ships with.
    static let shipped = BillingLivePolicy(liveCheckout: false)

    func refuses(_ url: URL) -> Bool {
        !liveCheckout && StripeCheckoutMode(url: url) == .live
    }
}
