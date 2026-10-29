import CmuxCloud
import CmuxProductAnalytics

extension ProductAnalyticsEvent {
    /// An upgrade click from `source`. The same token reaches checkout as
    /// `cmux_source`, so this joins `cmux_billing_checkout_*` on `checkout_source`.
    static func upgradeOpened(
        _ source: ProUpgradeSource,
        plan: CheckoutPlan = .pro,
        destination: UpgradeDestination
    ) -> Self {
        .upgradeEntrypointOpened(source: source.rawValue, plan: plan.rawValue, destination: destination)
    }

    /// An upgrade entrypoint from `source` became visible.
    static func upgradeShown(_ source: ProUpgradeSource, plan: CheckoutPlan = .pro) -> Self {
        .upgradePromptShown(source: source.rawValue, plan: plan.rawValue)
    }
}
