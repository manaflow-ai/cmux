#if os(iOS)
import CmuxMobileBilling
import CmuxMobileSupport
import SwiftUI
@preconcurrency import UserNotifications

// The `checklist`, `planTabs`, `hero` and `trialTimeline` paywall layouts.
// Every number in their copy comes from the published pricing facts or from
// StoreKit; none shows a struck-through anchor price or an unproven
// multiplier, and none has a "No thanks" button: the close button is the way
// out.

/// One row of the `checklist` table: what Free and Pro include.
struct MobilePaywallChecklistRow: Hashable {
    let title: String
    let free: Bool
    let pro: Bool

    /// The rows, from the published pricing facts.
    static var rows: [MobilePaywallChecklistRow] {
        [
            .init(title: L10n.string("mobile.billing.checklist.machines", defaultValue: "Up to 5 Cloud VMs"), free: false, pro: true),
            .init(title: L10n.string("mobile.billing.checklist.pool", defaultValue: "20 vCPUs and 40 GB RAM shared"), free: false, pro: true),
            .init(title: L10n.string("mobile.billing.checklist.size", defaultValue: "VMs up to 8 vCPUs and 16 GB"), free: false, pro: true),
            .init(title: L10n.string("mobile.billing.checklist.apps", defaultValue: "iPhone and Mac apps"), free: true, pro: true),
            .init(title: L10n.string("mobile.billing.checklist.support", defaultValue: "Email support"), free: false, pro: true),
        ]
    }
}

/// Free against Pro, one check per row.
struct MobilePaywallChecklist: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("mobile.billing.checklist.features", defaultValue: "Features"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(BillingPlanCopy(planID: .free).name)
                    .frame(width: 52)
                Text(BillingPlanCopy(planID: .pro).name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .frame(width: 52)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.bottom, 10)
            ForEach(MobilePaywallChecklistRow.rows, id: \.self) { row in
                HStack {
                    Text(row.title)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    mark(row.free).frame(width: 52)
                    mark(row.pro).frame(width: 52)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier("BillingPaywallChecklist")
    }

    @ViewBuilder
    private func mark(_ included: Bool) -> some View {
        if included {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel(L10n.string("mobile.billing.compare.included", defaultValue: "Included"))
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(L10n.string("mobile.billing.checklist.notIncluded", defaultValue: "Not included"))
        }
    }
}

/// Pro and Max tabs: the chosen plan's benefits and its billing periods as
/// two large cards, yearly first.
struct MobilePaywallPlanTabs: View {
    let plans: [BillingPlanID]
    @Binding var selectedPlan: BillingPlanID
    /// The chosen plan's offers, one per period.
    let offers: [BillingOffer]
    @Binding var period: BillingPeriod
    let savingsPercent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if plans.count > 1 {
                Picker(L10n.string("mobile.billing.planTabs.plan", defaultValue: "Plan"), selection: $selectedPlan) {
                    ForEach(plans, id: \.self) { plan in
                        Text(BillingPlanCopy(planID: plan).name).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("BillingPaywallPlanTabs")
            }
            VStack(alignment: .leading, spacing: 10) {
                if selectedPlan == .max {
                    Text(L10n.string("mobile.billing.planTabs.everythingInPro", defaultValue: "Everything in Pro, plus:"))
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(benefits, id: \.self) { benefit in
                    Label {
                        Text(benefit).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            HStack(spacing: 12) {
                ForEach(offers.sorted { $0.billingPeriod > $1.billingPeriod }) { offer in
                    periodCard(offer)
                }
            }
        }
    }

    private var benefits: [String] {
        switch selectedPlan {
        case .max:
            [
                L10n.string("mobile.billing.plan.max.size", defaultValue: "Sharing 80 vCPUs and 160 GB RAM"),
                L10n.string("mobile.billing.planTabs.max.largest", defaultValue: "VMs up to 32 vCPUs and 64 GB RAM"),
            ]
        default:
            [
                L10n.string("mobile.billing.checklist.machines", defaultValue: "Up to 5 Cloud VMs"),
                L10n.string("mobile.billing.plan.pro.size", defaultValue: "Sharing 20 vCPUs and 40 GB RAM"),
                L10n.string("mobile.billing.checklist.size", defaultValue: "VMs up to 8 vCPUs and 16 GB"),
                L10n.string("mobile.billing.checklist.support", defaultValue: "Email support"),
            ]
        }
    }

    private func periodCard(_ offer: BillingOffer) -> some View {
        let isSelected = offer.billingPeriod == period
        return Button {
            period = offer.billingPeriod
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(offer.billingPeriod == .yearly
                        ? L10n.string("mobile.billing.period.yearly", defaultValue: "Yearly")
                        : L10n.string("mobile.billing.period.monthly", defaultValue: "Monthly"))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if offer.billingPeriod == .yearly, let savingsPercent {
                        MobilePaywallBadge(
                            text: String(
                                format: L10n.string("mobile.billing.paywall.savePercent", defaultValue: "Save %lld%%"),
                                Int64(savingsPercent)
                            ),
                            tone: .savings
                        )
                    }
                }
                Text(BillingPriceCopy.price(offer))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                if let monthly = offer.product.monthlyEquivalentDisplayPrice {
                    Text(String(
                        format: L10n.string("mobile.billing.planTabs.perMonth", defaultValue: "%@/month"),
                        monthly
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("BillingPaywallPeriodCard.\(offer.billingPeriod.rawValue)")
    }
}

/// The `hero` header: cmux art (a terminal on a cloud) on a dark field, the
/// headline and the subheadline. Our own drawing, not a stock image.
struct MobilePaywallHeroHeader: View {
    let headline: String
    let subheadline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MobilePaywallTerminalArt()
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            Text(verbatim: headline)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !subheadline.isEmpty {
                Text(verbatim: subheadline)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Color(white: 0.02), Color(white: 0.11)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .environment(\.colorScheme, .dark)
    }
}

/// A terminal window floating over a soft cloud, drawn in SwiftUI.
struct MobilePaywallTerminalArt: View {
    var body: some View {
        ZStack {
            Image(systemName: "cloud.fill")
                .font(.system(size: 150))
                .foregroundStyle(.white.opacity(0.07))
                .offset(x: 40, y: -6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(.white.opacity(0.25)).frame(width: 8, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "$ cmux vm new")
                        .foregroundStyle(.white.opacity(0.9))
                    Text(verbatim: "● agent  running  12m")
                        .foregroundStyle(.green.opacity(0.85))
                    Text(verbatim: "● agent  running   3m")
                        .foregroundStyle(.green.opacity(0.85))
                    HStack(spacing: 0) {
                        Text(verbatim: "$ ")
                        Rectangle().fill(.white.opacity(0.8)).frame(width: 8, height: 14)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(12)
            }
            .frame(width: 230)
            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        }
        .frame(height: 150)
        .dynamicTypeSize(.large)
    }
}

/// Four benefit rows with icons and checks.
struct MobilePaywallHeroBenefits: View {
    /// The configured bullets; nil or empty uses the built-in four.
    let bullets: [String]

    private struct Benefit: Hashable {
        let icon: String
        let text: String
    }

    private var benefits: [Benefit] {
        let icons = ["server.rack", "cpu", "moon.zzz", "iphone"]
        let defaults = [
            L10n.string("mobile.billing.checklist.machines", defaultValue: "Up to 5 Cloud VMs"),
            L10n.string("mobile.billing.checklist.pool", defaultValue: "20 vCPUs and 40 GB RAM shared"),
            L10n.string("mobile.billing.hero.sleep", defaultValue: "Agents keep working when your Mac sleeps"),
            L10n.string("mobile.billing.hero.phone", defaultValue: "Check in on agents from your iPhone"),
        ]
        let texts = bullets.isEmpty ? defaults : Array(bullets.prefix(4))
        return texts.enumerated().map { Benefit(icon: icons[$0.offset % icons.count], text: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(benefits, id: \.self) { benefit in
                HStack(spacing: 12) {
                    Image(systemName: benefit.icon)
                        .font(.body.weight(.medium))
                        .frame(width: 28)
                        .foregroundStyle(.secondary)
                    Text(verbatim: benefit.text)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Pro and Max side by side as small price tiles, by the button.
struct MobilePaywallTierSelector: View {
    let offers: [BillingOffer]
    let selectedPlan: BillingPlanID?
    let select: (BillingPlanID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(offers) { offer in
                let isSelected = offer.planID == selectedPlan
                Button {
                    select(offer.planID)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(BillingPlanCopy(planID: offer.planID).name)
                            .font(.subheadline.weight(.semibold))
                        Text(BillingPriceCopy.price(offer))
                            .font(.headline)
                            .monospacedDigit()
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("BillingPaywallTier.\(offer.planID.rawValue)")
            }
        }
    }
}

/// The trial as a timeline: today, the reminder (only when the app will
/// really send it), and the day the first charge happens.
struct MobilePaywallTrialTimeline: View {
    let grant: BillingTrialGrant
    /// Whether the reminder notification will be sent: false once the user
    /// declined notifications, which removes its row.
    let showsReminder: Bool

    var body: some View {
        let days = BillingTrialReminder.trialDays(grant.offer)
        VStack(alignment: .leading, spacing: 0) {
            row(
                icon: "lock.open.fill",
                title: L10n.string("mobile.billing.timeline.today", defaultValue: "Today"),
                detail: todayDetail,
                isLast: false
            )
            if showsReminder, let reminderDay = BillingTrialReminder.reminderDay(trialDays: days) {
                row(
                    icon: "bell.fill",
                    title: String(
                        format: L10n.string("mobile.billing.timeline.day", defaultValue: "Day %lld"),
                        Int64(reminderDay)
                    ),
                    detail: L10n.string(
                        "mobile.billing.timeline.reminder",
                        defaultValue: "We send you a reminder that your trial is ending."
                    ),
                    isLast: false
                )
            }
            row(
                icon: "star.fill",
                title: String(
                    format: L10n.string("mobile.billing.timeline.day", defaultValue: "Day %lld"),
                    Int64(days)
                ),
                detail: String(
                    format: L10n.string(
                        "mobile.billing.timeline.charge",
                        defaultValue: "%@ starts. Cancel anytime before then."
                    ),
                    BillingPriceCopy.price(grant.billingOffer)
                ),
                isLast: true
            )
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("BillingPaywallTrialTimeline")
    }

    private var todayDetail: String {
        if let limits = BillingPriceCopy.trialLimits(grant.limits) {
            return String(
                format: L10n.string("mobile.billing.timeline.todayLimits", defaultValue: "Your %1$@ trial starts: %2$@."),
                BillingPlanCopy(planID: grant.planID).name,
                limits
            )
        }
        return String(
            format: L10n.string("mobile.billing.timeline.todayPlain", defaultValue: "Your %@ trial starts."),
            BillingPlanCopy(planID: grant.planID).name
        )
    }

    private func row(icon: String, title: String, detail: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2).frame(minHeight: 24)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 14)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The local reminder before a free trial ends. The timeline promises it
/// only while notifications are allowed or not asked yet; the app asks
/// when the user starts the trial, and drops the promise if they decline.
@MainActor
enum BillingTrialReminder {
    static let identifier = "dev.cmux.billing.trial-reminder"

    /// The trial length in days.
    static func trialDays(_ offer: StoreIntroductoryOffer) -> Int {
        let total = offer.periodValue * max(offer.periodCount, 1)
        switch offer.periodUnit {
        case .day: return total
        case .week: return total * 7
        case .month: return total * 30
        case .year: return total * 365
        }
    }

    /// The reminder day: two days before the end; nil for trials too short
    /// to remind.
    static func reminderDay(trialDays: Int) -> Int? {
        trialDays >= 4 ? trialDays - 2 : nil
    }

    /// Whether the reminder can still be sent: notifications allowed, or
    /// not asked yet.
    static func canRemind() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return false
        default: return true
        }
    }

    /// Asks for notification permission when it was never asked.
    /// - Returns: Whether reminders can be delivered.
    static func requestIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default: return false
        }
    }

    /// Schedules the reminder `reminderDay` days from now.
    static func schedule(grant: BillingTrialGrant, startedAt: Date = .now) async {
        let days = trialDays(grant.offer)
        guard let reminderDay = reminderDay(trialDays: days),
              let endDate = grant.offer.endDate(from: startedAt)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.string("mobile.billing.reminder.title", defaultValue: "Your cmux trial ends in 2 days")
        content.body = String(
            format: L10n.string(
                "mobile.billing.reminder.body",
                defaultValue: "%1$@ starts on %2$@ at %3$@. Cancel anytime before then in Settings > Apple Account > Subscriptions."
            ),
            BillingPlanCopy(planID: grant.planID).name,
            endDate.formatted(date: .long, time: .omitted),
            BillingPriceCopy.price(grant.billingOffer)
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(reminderDay) * 86_400, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
