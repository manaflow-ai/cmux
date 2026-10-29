import CmuxNextActions
import Foundation

/// Upgrade to cmux Pro (`palette.pro.upgrade`): the one paid-plan path (``PaidPlanUpgrade``), a
/// Checkout page on cmux.com that returns to this app, else the pricing page (the app takes no
/// payment itself).
@MainActor
struct UpgradeToPro {
    static let pricingURL = StaticURL.pricing.url

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // The Checkout session comes from the network before its page opens (`PaidPlanUpgrade`).
        // action-wait-allow: the Checkout page's URL is known only when cmux.com answers; the pricing page is the fallback.
        registry.bindEffect("palette.pro.upgrade", effect: { _ in
            .waiting(.network) { await context.services.paidPlanUpgrade().start(source: .palette); return nil }
        })
    }
}
