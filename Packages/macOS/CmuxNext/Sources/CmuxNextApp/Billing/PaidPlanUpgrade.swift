import CmuxNextAccounts
import Foundation

/// The one upgrade path every paywall in the app takes (plans/cmux-next/paid-plans-DESIGN.md §2):
/// the Cloud create gate, the Cloud server's refusal, the palette's "Upgrade to cmux Pro", and the
/// model router's "See plans". It asks cmux.com for a Checkout page bound to the signed-in account
/// that returns to this app (`cmux_scheme`), and opens it; signed out, a failed request, or a page
/// the app may not open (a live-mode session while real charges are off) opens the refusal's own
/// link, else the pricing page. It marks the upgrade pending, so the plan turning paid shows the
/// welcome step (``PaidPlanOnboarding``).
@MainActor
struct PaidPlanUpgrade {
    /// Which paywall asked (logs only; every source takes the same path).
    enum Source: String, Sendable { case palette, cloudCreate, cloudRefusal, inference }

    /// What opened.
    enum Outcome: Equatable, Sendable {
        case checkout(URL)
        case pricing(URL)
    }

    /// A Checkout page for `plan` returning to `scheme`; nil when no account is signed in.
    var checkout: (@MainActor (_ plan: String, _ scheme: String) async throws -> URL)?
    var open: @MainActor (URL) -> Void
    /// This build's callback scheme (`cmux-next`, `cmux-dev-<tag>`, ...).
    var scheme: String
    var onboarding: PaidPlanOnboarding
    var pricing: URL = StaticURL.pricing.url

    @discardableResult
    func start(plan: String = "pro", source: Source, fallback: URL? = nil) async -> Outcome {
        onboarding.markPending(plan)
        if let checkout, let url = try? await checkout(plan, scheme), Self.opens(url) {
            open(url)
            return .checkout(url)
        }
        let page = fallback ?? pricing
        open(page)
        return .pricing(page)
    }

    /// A test-mode Stripe page, or a cmux.com page (an already-active plan's dashboard). Never a live
    /// session while real charges are off (``BillingLivePolicy``), nor a host the app does not know.
    static func opens(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", !BillingLivePolicy.shipped.refuses(url) else { return false }
        switch StripeCheckoutMode(url: url) {
        case .test: return true
        case .live: return false
        case .unknown:
            let host = url.host?.lowercased() ?? ""
            return host == "cmux.com" || host.hasSuffix(".cmux.com")
        }
    }
}
