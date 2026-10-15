#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI

/// Prices and trial terms in words, from StoreKit values only.
enum BillingPriceCopy {
    /// "$74.99/month", or the bare price when StoreKit has no period.
    static func price(_ offer: BillingOffer) -> String {
        guard let unit = offer.product.periodUnitName, !unit.isEmpty else { return offer.product.displayPrice }
        return String(
            format: L10n.string("mobile.billing.pricePerPeriodShort", defaultValue: "%1$@/%2$@"),
            offer.product.displayPrice,
            unit
        )
    }

    /// The trial's length, such as "7 days".
    static func trialLength(_ offer: StoreIntroductoryOffer) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .month, .year]
        return formatter.string(from: offer.duration) ?? ""
    }

    /// "7 days free, then $74.99/month".
    static func trialHeadline(_ grant: BillingTrialGrant) -> String {
        String(
            format: L10n.string("mobile.billing.trial.headline", defaultValue: "%1$@ free, then %2$@"),
            trialLength(grant.offer),
            price(grant.billingOffer)
        )
    }

    /// "1 Cloud VM, 2 vCPUs and 4 GB RAM, 20 VM-hours"; nil without limits.
    static func trialLimits(_ limits: BillingTrialLimits?) -> String? {
        guard let limits else { return nil }
        var parts: [String] = []
        if let machines = limits.machines {
            parts.append(String(
                format: L10n.string("mobile.billing.trial.limit.machines", defaultValue: "Cloud VMs at a time: %lld"),
                Int64(machines)
            ))
        }
        if let vcpus = limits.vcpus, let memory = limits.memoryGb {
            parts.append(String(
                format: L10n.string("mobile.billing.trial.limit.size", defaultValue: "%1$lld vCPUs and %2$lld GB RAM"),
                Int64(vcpus),
                Int64(memory)
            ))
        }
        if let hours = limits.vmHours {
            parts.append(String(
                format: L10n.string("mobile.billing.trial.limit.hours", defaultValue: "VM-hours: %lld"),
                Int64(hours)
            ))
        }
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }
}

/// The paywall's title block: plain text from the server configuration.
struct MobilePaywallHeader: View {
    let config: BillingPaywallConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "cloud.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 52, height: 52)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            // Verbatim: server text is plain, never Markdown.
            Text(verbatim: config.headline)
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("BillingPaywallHeadline")
            if !config.subheadline.isEmpty {
                Text(verbatim: config.subheadline)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The configuration's selling points.
struct MobilePaywallBullets: View {
    let bullets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                Label {
                    Text(verbatim: bullet)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("BillingPaywallBullets")
    }
}

/// Monthly and Yearly, with the yearly saving computed from StoreKit prices.
struct MobilePaywallPeriodPicker: View {
    @Binding var period: BillingPeriod
    let savingsPercent: Int?

    var body: some View {
        VStack(spacing: 8) {
            Picker(L10n.string("mobile.billing.period", defaultValue: "Billing period"), selection: $period) {
                Text(L10n.string("mobile.billing.period.monthly", defaultValue: "Monthly"))
                    .tag(BillingPeriod.monthly)
                Text(L10n.string("mobile.billing.period.yearly", defaultValue: "Yearly"))
                    .tag(BillingPeriod.yearly)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("BillingPeriodPicker")
            if let savingsPercent {
                Text(String(
                    format: L10n.string(
                        "mobile.billing.paywall.yearlySavings",
                        defaultValue: "Save up to %lld%% with yearly billing"
                    ),
                    Int64(savingsPercent)
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("BillingPaywallYearlySavings")
            }
        }
    }
}

/// A small capsule label.
struct MobilePaywallBadge: View {
    enum Tone { case neutral, savings, emphasis }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .neutral: .secondary
        case .savings: .green
        case .emphasis: Color(.systemBackground)
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.07)
        case .savings: Color.green.opacity(0.14)
        case .emphasis: Color.primary
        }
    }
}

/// One plan on sale. Tapping selects it; the purchase bar buys the selection.
struct MobilePaywallPlanCard: View {
    enum Style { case standard, compact, hero }

    let offer: BillingOffer
    let style: Style
    let isSelected: Bool
    let isRecommended: Bool
    let isCurrent: Bool
    let savingsPercent: Int?
    let trial: BillingTrialGrant?
    let select: () -> Void

    var body: some View {
        let copy = BillingPlanCopy(planID: offer.planID)
        Button(action: select) {
            VStack(alignment: .leading, spacing: style == .compact ? 4 : 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(copy.name)
                        .font(style == .hero ? .title2.bold() : .headline)
                    badges
                    Spacer(minLength: 8)
                    if style == .compact {
                        priceLabel
                    } else {
                        selectionMark
                    }
                }
                if style != .compact {
                    priceLabel
                }
                if let monthly = offer.product.monthlyEquivalentDisplayPrice {
                    Text(String(
                        format: L10n.string("mobile.billing.monthlyEquivalent", defaultValue: "%@ / month, billed yearly"),
                        monthly
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("BillingOfferMonthlyEquivalent.\(offer.planID.rawValue)")
                }
                if style != .compact {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(copy.features, id: \.self) { feature in
                            Label {
                                Text(feature)
                            } icon: {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(style == .hero ? 20 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: style == .compact ? 14 : 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: style == .compact ? 14 : 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.primary : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("BillingOfferCard.\(offer.planID.rawValue)")
    }

    private var priceLabel: some View {
        Text(BillingPriceCopy.price(offer))
            .font(style == .compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
            .monospacedDigit()
            .accessibilityIdentifier("BillingOfferPrice.\(offer.planID.rawValue)")
    }

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badges: some View {
        if isCurrent {
            MobilePaywallBadge(text: L10n.string("mobile.billing.offer.current", defaultValue: "Current Plan"))
        } else if let trial {
            MobilePaywallBadge(
                text: String(
                    format: L10n.string("mobile.billing.trial.badge", defaultValue: "%@ free"),
                    BillingPriceCopy.trialLength(trial.offer)
                ),
                tone: .emphasis
            )
        } else if let savingsPercent {
            MobilePaywallBadge(
                text: String(
                    format: L10n.string("mobile.billing.paywall.savePercent", defaultValue: "Save %lld%%"),
                    Int64(savingsPercent)
                ),
                tone: .savings
            )
            .accessibilityIdentifier("BillingOfferSavings.\(offer.planID.rawValue)")
        } else if isRecommended {
            MobilePaywallBadge(text: L10n.string("mobile.billing.paywall.recommended", defaultValue: "Recommended"))
        }
    }
}

/// Free, Pro and Max side by side, from the published pricing facts.
struct MobilePaywallComparison: View {
    let plans: [BillingPlanID]
    let highlighted: BillingPlanID?
    /// Stack one plan per block at accessibility text sizes.
    let accessibilityLayout: Bool

    var body: some View {
        Group {
            if accessibilityLayout {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plans, id: \.self) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(BillingPlanCopy(planID: plan).name).font(.headline)
                            ForEach(BillingComparisonRow.allCases, id: \.self) { row in
                                Text(verbatim: "\(row.title): \(value(row, plan))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                    GridRow {
                        Color.clear.frame(height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(plans, id: \.self) { plan in
                            Text(BillingPlanCopy(planID: plan).name)
                                .font(.subheadline.weight(plan == highlighted ? .bold : .semibold))
                                .foregroundStyle(plan == .free ? Color.secondary : Color.primary)
                                .gridColumnAlignment(.center)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(BillingComparisonRow.allCases, id: \.self) { row in
                        GridRow {
                            Text(row.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(plans, id: \.self) { plan in
                                Text(value(row, plan))
                                    .font(.footnote.weight(plan == highlighted ? .semibold : .regular))
                                    .foregroundStyle(plan == .free ? Color.secondary : Color.primary)
                                    .multilineTextAlignment(.center)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier("BillingPaywallComparison")
    }

    private func value(_ row: BillingComparisonRow, _ plan: BillingPlanID) -> String {
        BillingPlanCopy(planID: plan).comparisonValue(row) ?? "—"
    }
}

/// The free trial's terms: length, the price after it, the date of the first
/// charge, how to cancel, and the trial's limits (App Review 3.1.2).
struct MobilePaywallTrialTerms: View {
    let grant: BillingTrialGrant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(BillingPriceCopy.trialHeadline(grant))
                .font(.headline)
            if let endDate = grant.offer.endDate(from: .now) {
                Text(String(
                    format: L10n.string(
                        "mobile.billing.trial.firstCharge",
                        defaultValue: "Your first payment of %1$@ is on %2$@ unless you cancel before then. Cancel at least 24 hours before the trial ends in Settings > Apple Account > Subscriptions."
                    ),
                    grant.product.displayPrice,
                    endDate.formatted(date: .long, time: .omitted)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let limits = BillingPriceCopy.trialLimits(grant.limits) {
                Text(String(
                    format: L10n.string(
                        "mobile.billing.trial.limits",
                        defaultValue: "During the trial: %1$@. Full %2$@ starts when the trial ends."
                    ),
                    limits,
                    BillingPlanCopy(planID: grant.planID).name
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("BillingPaywallTrialTerms")
    }
}

/// Restore Purchases, Terms, Privacy and the auto-renewal disclosure.
struct MobilePaywallLegal: View {
    let isBusy: Bool
    let restore: () -> Void

    /// The Terms of Use page.
    static let termsURL = URL(string: "https://cmux.com/terms-of-service")!
    /// The Privacy Policy page.
    static let privacyURL = URL(string: "https://cmux.com/privacy-policy")!

    var body: some View {
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { links }
                VStack(spacing: 10) { links }
            }
            .font(.footnote.weight(.medium))
            Text(L10n.string(
                "mobile.billing.disclosure",
                defaultValue: "Subscriptions renew automatically at the end of each month or year, as shown, at the price shown until cancelled. Payment is charged to your Apple Account when you confirm the purchase. Your account is charged for renewal within 24 hours before the current period ends unless auto-renew is turned off at least 24 hours before then. Manage or cancel your subscription in your Apple Account settings."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var links: some View {
        Button(L10n.string("mobile.billing.restore", defaultValue: "Restore Purchases"), action: restore)
            .disabled(isBusy)
            .accessibilityIdentifier("BillingRestore")
        Link(L10n.string("mobile.billing.terms", defaultValue: "Terms of Use"), destination: Self.termsURL)
        Link(L10n.string("mobile.billing.privacy", defaultValue: "Privacy Policy"), destination: Self.privacyURL)
    }
}

/// The pinned purchase button with the selected plan's price and renewal
/// terms right next to it.
struct MobilePaywallPurchaseBar: View {
    let offer: BillingOffer
    let config: BillingPaywallConfig
    let trial: BillingTrialGrant?
    let isCurrent: Bool
    let isSwitch: Bool
    let isBusy: Bool
    let isPreview: Bool
    let statusMessage: String?
    let buy: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let statusMessage {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("BillingResult")
            }
            if let priceLine {
                // The amount billed, as prominent as the button (App Review
                // 3.1.2): the trial's terms, or the price when the button
                // names an action.
                Text(priceLine)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("BillingPaywallPriceLine")
            }
            Button(action: buy) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(MobilePaywallPrimaryButtonStyle())
            .disabled(isCurrent || isBusy || isPreview)
            .accessibilityIdentifier("BillingPaywallCTA")
            Text(renewal)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("BillingPaywallRenewal")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var title: String {
        let planName = BillingPlanCopy(planID: offer.planID).name
        if isCurrent {
            return L10n.string("mobile.billing.offer.current", defaultValue: "Current Plan")
        }
        if trial != nil {
            return L10n.string("mobile.billing.trial.cta", defaultValue: "Start Free Trial")
        }
        if isSwitch {
            return String(
                format: L10n.string("mobile.billing.paywall.switchTo", defaultValue: "Switch to %@"),
                planName
            )
        }
        switch config.ctaStyle {
        case .price:
            return String(
                format: L10n.string("mobile.billing.paywall.subscribeFor", defaultValue: "Subscribe for %@"),
                BillingPriceCopy.price(offer)
            )
        case .action:
            return String(
                format: L10n.string("mobile.billing.paywall.continueWith", defaultValue: "Continue with %@"),
                planName
            )
        }
    }

    private var priceLine: String? {
        if let trial { return BillingPriceCopy.trialHeadline(trial) }
        guard !isCurrent, config.ctaStyle == .action || isSwitch else { return nil }
        return BillingPriceCopy.price(offer)
    }

    private var renewal: String {
        if trial != nil {
            return L10n.string("mobile.billing.paywall.cancelAnytime", defaultValue: "Renews automatically until cancelled.")
        }
        return String(
            format: L10n.string(
                "mobile.billing.paywall.renews",
                defaultValue: "%1$@ %2$@, renews automatically until cancelled."
            ),
            BillingPlanCopy(planID: offer.planID).name,
            BillingPriceCopy.price(offer)
        )
    }
}

/// The primary action: a solid label-colored fill, inverted text.
struct MobilePaywallPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(.systemBackground))
            .background(
                Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A short explanation with an icon, for states without offers.
struct MobilePaywallNotice: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shown after the server applied the new plan.
struct MobilePaywallSuccess: View {
    let planID: BillingPlanID
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(String(
                format: L10n.string("mobile.billing.completed", defaultValue: "You're on %@ now."),
                BillingPlanCopy(planID: planID).name
            ))
            .font(.title2.bold())
            .multilineTextAlignment(.center)
            Text(L10n.string(
                "mobile.billing.paywall.successBody",
                defaultValue: "Your new plan is active. Create a Cloud machine from the Cloud tab."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button(action: done) {
                Text(L10n.string("mobile.billing.done", defaultValue: "Done"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(MobilePaywallPrimaryButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .accessibilityIdentifier("BillingPaywallSuccess")
    }
}
#endif
