import CmuxNextActions
import Foundation

/// Upgrade to cmux Pro (`palette.pro.upgrade`): opens the cmux pricing page,
/// where checkout runs (the app takes no payment itself).
@MainActor
struct UpgradeToPro {
    static let pricingURL = StaticURL.pricing.url

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("palette.pro.upgrade", effect: { _ in context.open(pricingURL) })
    }
}
