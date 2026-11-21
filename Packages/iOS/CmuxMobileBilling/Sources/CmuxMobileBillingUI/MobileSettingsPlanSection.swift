#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// The Settings row that shows the current plan and opens the plans screen.
///
/// Renders nothing when the host injected no ``BillingModel``.
///
/// HIG: Settings (a summary row that navigates to its detail page).
public struct MobileSettingsPlanSection: View {
    @Environment(BillingModel.self) private var billing: BillingModel?

    /// Creates the section.
    public init() {}

    public var body: some View {
        if let billing {
            Section {
                NavigationLink {
                    MobilePlansView(entryPoint: .settings)
                        .environment(billing)
                } label: {
                    LabeledContent {
                        if let account = billing.account.account {
                            Text(BillingPlanCopy(planID: account.currentPlan.planID).name)
                        }
                    } label: {
                        Label(
                            L10n.string("mobile.billing.settingsRow", defaultValue: "Plan"),
                            systemImage: "creditcard"
                        )
                    }
                }
                .accessibilityIdentifier("MobileSettingsPlanRow")
            }
            .task {
                if billing.account.account == nil { await billing.refresh() }
            }
        }
    }
}
#endif
