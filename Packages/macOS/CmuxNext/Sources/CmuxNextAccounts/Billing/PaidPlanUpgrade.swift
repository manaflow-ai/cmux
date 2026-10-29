package import CmuxNextCodeRouter
package import Foundation

/// The one upgrade path every paywall in the app takes (plans/cmux-next/paid-plans-DESIGN.md §2):
/// the Cloud create gate, the Cloud server's refusal, the palette's "Upgrade to cmux Pro", and the
/// model router's "See plans". It asks cmux.com for a Checkout page bound to the signed-in account
/// that returns to this app (`cmux_scheme`), and opens it; signed out, a failed request, or a page
/// the app may not open (a live-mode session while real charges are off) opens the refusal's own
/// link, else the pricing page. It marks the upgrade pending, so the plan turning paid shows the
/// welcome step (``PaidPlanOnboarding``).
@MainActor
package struct PaidPlanUpgrade {
    /// Which paywall asked (logs only; every source takes the same path).
    package enum Source: String, Sendable { case palette, cloudCreate, cloudRefusal, inference }

    /// What opened.
    package enum Outcome: Equatable, Sendable {
        case checkout(URL)
        case pricing(URL)
    }

    /// A Checkout page for `plan` returning to `scheme`; nil when no account is signed in.
    package var checkout: (@MainActor (_ plan: String, _ scheme: String) async throws -> URL)?
    package var open: @MainActor (URL) -> Void
    /// This build's callback scheme (`cmux-next`, `cmux-dev-<tag>`, ...).
    package var scheme: String
    package var onboarding: PaidPlanOnboarding
    /// The pricing page (the app's `StaticURL.pricing`).
    package var pricing: URL

    package init(checkout: (@MainActor (_ plan: String, _ scheme: String) async throws -> URL)?, open: @escaping @MainActor (URL) -> Void,
                 scheme: String, onboarding: PaidPlanOnboarding, pricing: URL) {
        self.checkout = checkout
        self.open = open
        self.scheme = scheme
        self.onboarding = onboarding
        self.pricing = pricing
    }

    @discardableResult
    package func start(plan: String = "pro", source: Source, fallback: URL? = nil) async -> Outcome {
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
    package static func opens(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", !BillingLivePolicy.shipped.refuses(url) else { return false }
        switch StripeCheckoutMode(url: url) {
        case .test: return true
        case .live: return false
        case .unknown:
            let host = url.host?.lowercased() ?? ""
            return host == "cmux.com" || host.hasSuffix(".cmux.com")
        }
    }

    /// The checkout over cmux.com's native route (`POST /api/billing/checkout`, the CLI's `billing.checkout`) as the
    /// account `client` signs in, returning to `scheme`.
    package static func cmuxComCheckout(_ client: CodeRouterClient) -> @MainActor (String, String) async throws -> URL {
        { plan, scheme in
            let body = try BillingCheckoutRequest(plan: plan, team: nil, scheme: scheme).body
            let data = try await client.request("POST", "/api/billing/checkout", body: body)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["url"] as? String, let url = URL(string: raw) else { throw URLError(.badServerResponse) }
            return url
        }
    }
}
