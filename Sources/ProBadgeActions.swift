import CmuxCloud
import CmuxProductAnalytics

/// What the sidebar footer's Upgrade badge does, with its analytics. The view
/// calls these; tests call them with a recording emitter and a no-op opener.
@MainActor
struct ProBadgeActions {
    static let source = ProUpgradeSource.sidebarBadge

    var analytics: ProductAnalytics = .app
    var openPricing: @MainActor (ProUpgradeSource) -> Void = { ProUpgradePresenter.presentAppPricingWeb(source: $0) }

    /// The badge is on screen.
    func appeared() {
        analytics.track(.upgradeShown(Self.source))
    }

    /// The badge was clicked: records the click with its source and opens pricing.
    func upgrade() {
        ProUpgradePresenter.present(source: Self.source, analytics: analytics, open: openPricing)
    }

    /// The badge's X hid it.
    func dismissed() {
        analytics.track(.upgradeBadgeDismissed(source: Self.source.rawValue))
    }
}
