#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// Staff-only Paywall Lab: every live and retired paywall variant from the
/// server, each rendered in the real paywall view with real StoreKit prices,
/// in any layout, for any entry point, and in the trial and not-eligible
/// states. Purchases and analytics are off in the lab.
///
/// Settings shows the row only when the account-token response marks the
/// account as staff; the variants route is staff-only on the server too.
///
/// HIG: Lists and tables.
public struct MobilePaywallLabView: View {
    @Environment(BillingModel.self) private var billing
    @State private var variants: [BillingPaywallVariant] = []
    @State private var loadFailed = false
    @State private var isLoading = true

    /// Creates the lab.
    public init() {}

    public var body: some View {
        List {
            Section {
                variantLink(BillingPaywallVariant(status: "built_in", config: .control))
            } header: {
                Text(L10n.string("mobile.billing.lab.builtIn", defaultValue: "Built in"))
            } footer: {
                Text(L10n.string(
                    "mobile.billing.lab.builtInFooter",
                    defaultValue: "Shown when the server sends no paywall configuration or an invalid one."
                ))
            }
            Section {
                if isLoading {
                    ProgressView()
                } else if loadFailed {
                    Button(L10n.string("mobile.billing.retry", defaultValue: "Try Again")) {
                        Task { await load() }
                    }
                } else if variants.isEmpty {
                    Text(L10n.string("mobile.billing.lab.none", defaultValue: "The server lists no variants."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(variants) { variant in
                        variantLink(variant)
                    }
                }
            } header: {
                Text(L10n.string("mobile.billing.lab.server", defaultValue: "Server variants"))
            }
            Section {
                MobileUpgradeCard(
                    entryPoint: .paywallLab,
                    title: L10n.string("mobile.billing.upgrade.settings.title", defaultValue: "Upgrade to cmux Cloud"),
                    message: L10n.string(
                        "mobile.billing.upgrade.settings.message",
                        defaultValue: "Run coding agents on Cloud VMs that keep working when your Mac sleeps."
                    ),
                    open: {}
                )
            } header: {
                Text(L10n.string("mobile.billing.lab.settingsCard", defaultValue: "Settings card"))
            }
            Section {
                MobileUpgradeCard(
                    entryPoint: .paywallLab,
                    title: L10n.string("mobile.billing.upgrade.cloud.title", defaultValue: "Cloud VMs need a paid plan"),
                    message: L10n.string(
                        "mobile.billing.upgrade.cloud.message",
                        defaultValue: "Pro includes up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM."
                    ),
                    open: {}
                )
            } header: {
                Text(L10n.string("mobile.billing.lab.cloudBanner", defaultValue: "Cloud banner"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.billing.lab.title", defaultValue: "Paywall Lab"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .accessibilityIdentifier("BillingPaywallLab")
    }

    private func variantLink(_ variant: BillingPaywallVariant) -> some View {
        NavigationLink {
            MobilePaywallLabVariantView(variant: variant)
                .environment(billing)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: variant.config.variant)
                        .font(.body.weight(.medium))
                    Spacer()
                    MobilePaywallBadge(text: variant.status)
                }
                Text(verbatim: "\(variant.config.experiment) · \(variant.config.layout.rawValue) · \(variant.config.headline)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func load() async {
        isLoading = variants.isEmpty
        do {
            variants = try await billing.paywallVariants()
            loadFailed = false
        } catch {
            loadFailed = true
        }
        isLoading = false
    }
}

/// One variant in the lab: choose layout, entry point and state, then open
/// the real paywall sheet.
struct MobilePaywallLabVariantView: View {
    @Environment(BillingModel.self) private var billing
    let variant: BillingPaywallVariant
    @State private var layout: BillingPaywallLayout
    @State private var entryPoint: BillingEntryPoint = .settingsUpgradeCard
    @State private var scenario: BillingPaywallPreview.Scenario = .offers
    @State private var presented: BillingPaywallPreview?

    init(variant: BillingPaywallVariant) {
        self.variant = variant
        _layout = State(initialValue: variant.config.layout)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.string("mobile.billing.lab.experiment", defaultValue: "Experiment")) {
                    Text(verbatim: variant.config.experiment)
                }
                LabeledContent(L10n.string("mobile.billing.lab.variant", defaultValue: "Variant")) {
                    Text(verbatim: variant.config.variant)
                }
                LabeledContent(L10n.string("mobile.billing.lab.status", defaultValue: "Status")) {
                    Text(verbatim: variant.status)
                }
            }
            Section {
                Picker(L10n.string("mobile.billing.lab.layout", defaultValue: "Layout"), selection: $layout) {
                    ForEach(BillingPaywallLayout.allCases, id: \.self) { layout in
                        Text(verbatim: layout.rawValue).tag(layout)
                    }
                }
                Picker(L10n.string("mobile.billing.lab.entryPoint", defaultValue: "Entry point"), selection: $entryPoint) {
                    ForEach(BillingEntryPoint.allCases) { entryPoint in
                        Text(verbatim: entryPoint.rawValue).tag(entryPoint)
                    }
                }
                Picker(L10n.string("mobile.billing.lab.state", defaultValue: "State"), selection: $scenario) {
                    ForEach(BillingPaywallPreview.Scenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
            }
            Section {
                Button(L10n.string("mobile.billing.lab.open", defaultValue: "Open Paywall")) {
                    presented = BillingPaywallPreview(config: config, scenario: scenario, entryPoint: entryPoint)
                }
                .accessibilityIdentifier("BillingPaywallLabOpen")
            } footer: {
                Text(L10n.string(
                    "mobile.billing.lab.footer",
                    defaultValue: "Prices come from the App Store. Purchases and analytics are off in Paywall Lab."
                ))
            }
        }
        .navigationTitle(Text(verbatim: variant.config.variant))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presented) { preview in
            MobilePaywallSheet(entryPoint: preview.entryPoint, preview: preview)
                .environment(billing)
        }
    }

    /// The variant with the chosen layout.
    private var config: BillingPaywallConfig {
        let base = variant.config
        return BillingPaywallConfig(
            experiment: base.experiment,
            variant: base.variant,
            layout: layout,
            headline: base.headline,
            subheadline: base.subheadline,
            bullets: base.bullets,
            highlightedPlanID: base.highlightedPlanID,
            defaultBillingPeriod: base.defaultBillingPeriod,
            ctaStyle: base.ctaStyle,
            showYearlySavings: base.showYearlySavings,
            entryPointHeadlines: base.entryPointHeadlines,
            planSpecs: base.planSpecs
        ) ?? base
    }
}

extension BillingPaywallPreview: Identifiable {
    public var id: String {
        "\(config.experiment)/\(config.variant)/\(config.layout.rawValue)/\(scenario.rawValue)/\(entryPoint.rawValue)"
    }
}

extension BillingPaywallPreview.Scenario {
    var title: String {
        switch self {
        case .offers: L10n.string("mobile.billing.lab.scenario.offers", defaultValue: "Free account")
        case .trial: L10n.string("mobile.billing.lab.scenario.trial", defaultValue: "Trial offered")
        case .ineligibleWeb: L10n.string("mobile.billing.lab.scenario.web", defaultValue: "Not eligible: web subscriber")
        case .ineligibleTeam: L10n.string("mobile.billing.lab.scenario.team", defaultValue: "Not eligible: team billing")
        case .ineligibleUnavailable:
            L10n.string("mobile.billing.lab.scenario.unavailable", defaultValue: "Not eligible: purchases unavailable")
        }
    }
}
#endif
