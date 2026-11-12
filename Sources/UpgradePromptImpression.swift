import CmuxCloud
import CmuxProductAnalytics
import SwiftUI

extension View {
    /// Records `cmux_upgrade_prompt_shown` for `source` when this view
    /// appears. The pipeline keeps one per source per launch, so re-renders
    /// and remounts are free.
    func upgradePromptImpression(
        _ source: ProUpgradeSource,
        plan: CheckoutPlan = .pro,
        analytics: ProductAnalytics = .app
    ) -> some View {
        onAppear { analytics.track(.upgradeShown(source, plan: plan)) }
    }
}
