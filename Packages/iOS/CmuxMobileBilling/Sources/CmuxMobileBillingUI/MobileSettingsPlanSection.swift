#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// The Upgrade card at the top of Settings, for a signed-in Free account
/// that may buy in the App Store. Renders nothing otherwise, and nothing
/// when the host injected no ``BillingModel``.
///
/// HIG: In-app purchase and Settings.
public struct MobileSettingsUpgradeSection: View {
    @Environment(BillingModel.self) private var billing: BillingModel?
    @State private var paywall: BillingEntryPoint?

    /// Creates the section.
    public init() {}

    public var body: some View {
        // Kept while its paywall is open: a purchase makes the account paid,
        // and removing the section would close the paywall before its
        // success screen.
        if let billing, billing.canOfferUpgrade || paywall != nil {
            Section {
                MobileUpgradeCard(
                    entryPoint: .settingsUpgradeCard,
                    title: L10n.string("mobile.billing.upgrade.settings.title", defaultValue: "Upgrade to cmux Cloud"),
                    message: L10n.string(
                        "mobile.billing.upgrade.settings.message",
                        defaultValue: "Run coding agents on Cloud VMs that keep working when your Mac sleeps."
                    ),
                    open: { paywall = .settingsUpgradeCard }
                )
            }
            .billingPaywall($paywall)
        }
    }
}

/// The Settings rows for the account's plan: the current plan (opening the
/// plans screen), the free trial in progress, and for staff the Paywall Lab.
///
/// A Free account that may buy sees ``MobileSettingsUpgradeSection`` instead
/// of the Plan row. Renders nothing when the host injected no
/// ``BillingModel``.
///
/// HIG: Settings (a summary row that navigates to its detail page).
public struct MobileSettingsPlanSection: View {
    @Environment(BillingModel.self) private var billing: BillingModel?

    /// Creates the section.
    public init() {}

    public var body: some View {
        if let billing {
            Group {
                if !billing.canOfferUpgrade || billing.account.account?.staff == true {
                    Section {
                        if !billing.canOfferUpgrade {
                            planRow(billing)
                        }
                        if let trial = billing.account.account?.currentPlan.trial {
                            MobileTrialStatusRow(trial: trial, planID: billing.account.account?.currentPlan.planID ?? .pro)
                        }
                        if billing.account.account?.staff == true {
                            NavigationLink {
                                MobilePaywallLabView()
                                    .environment(billing)
                            } label: {
                                Label(
                                    L10n.string("mobile.billing.lab.title", defaultValue: "Paywall Lab"),
                                    systemImage: "flask"
                                )
                            }
                            .accessibilityIdentifier("MobileSettingsPaywallLabRow")
                        }
                    }
                }
            }
            .task { await billing.loadIfNeeded() }
        }
    }

    private func planRow(_ billing: BillingModel) -> some View {
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
}

/// A free trial in progress: when the paid plan starts, and the trial's
/// limits, stated plainly.
public struct MobileTrialStatusRow: View {
    private let trial: BillingActiveTrial
    private let planID: BillingPlanID

    /// Creates the row.
    public init(trial: BillingActiveTrial, planID: BillingPlanID) {
        self.trial = trial
        self.planID = planID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                L10n.string("mobile.billing.trial.active", defaultValue: "Free trial"),
                systemImage: "gift"
            )
            .font(.body)
            if let endsAt = trial.endsAt {
                Text(String(
                    format: L10n.string("mobile.billing.trial.endsOn", defaultValue: "Full %1$@ starts on %2$@."),
                    BillingPlanCopy(planID: planID).name,
                    endsAt.formatted(date: .long, time: .omitted)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if let limits = trial.limits?.summaryText {
                Text(String(
                    format: L10n.string("mobile.billing.trial.limitsNow", defaultValue: "During the trial: %@."),
                    limits
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BillingTrialStatus")
    }
}
#endif
