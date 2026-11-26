#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// The Settings row that shows the current plan and opens the plans screen.
///
/// Renders nothing when the host injected no ``BillingModel``. When the
/// plan's latest web renewal failed (``BillingModel/paymentPastDue``) the
/// section's footer says so.
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
            } footer: {
                if billing.paymentPastDue {
                    PaymentPastDueNotice()
                        .accessibilityIdentifier("MobileSettingsPlanPaymentPastDue")
                }
            }
            .task {
                if billing.account.account == nil { await billing.refresh() }
            }
        }
    }
}

/// The failed-renewal notice under the plan, in a section footer. Plain text:
/// the payment method of a web subscription is updated on the web, and the
/// App Store build links to no web billing (App Review Guideline 3.1.1).
struct PaymentPastDueNotice: View {
    var body: some View {
        Label {
            Text(BillingPlanCopy.paymentPastDue)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
#endif
