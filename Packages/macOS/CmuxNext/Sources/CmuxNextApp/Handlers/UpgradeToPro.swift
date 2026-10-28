import CmuxNextActions
import Foundation

/// Upgrade to cmux Pro (`palette.pro.upgrade`): the one paid-plan path (``PaidPlanUpgrade``), a
/// Checkout page on cmux.com that returns to this app, else the pricing page (the app takes no
/// payment itself).
@MainActor
struct UpgradeToPro {
    static let pricingURL = StaticURL.pricing.url

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.pro.upgrade", run: { _ in
            // task-owner: one upgrade start; ends when the page opened
            Task { await context.services.paidPlanUpgrade().start(source: .palette) }
        })
    }
}
