import CmuxNextAccounts
import CmuxNextActions
import Foundation

/// Upgrade to cmux Pro (`palette.pro.upgrade`): the one paid-plan path (``PaidPlanUpgrade``), a
/// Checkout page on cmux.com that returns to this app, else the pricing page (the app takes no
/// payment itself).
@MainActor
struct UpgradeToPro {
    static let pricingURL = StaticURL.pricing.url

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.pro.upgrade", run: { invocation in
            // The agent pane's Add Credits… names the model router's paywall; the source is for logs only.
            let source = invocation["source"]?.stringValue.flatMap(PaidPlanUpgrade.Source.init(rawValue:)) ?? .palette
            // task-owner: one upgrade start; ends when the page opened
            Task { await context.services.paidPlanUpgrade().start(source: source) }
        })
    }
}
