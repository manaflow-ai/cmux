import AppKit
import SwiftUI

// MARK: - Value-type snapshots
//
// Rows below the `ForEach(providersWithAccounts)` boundary receive these
// instead of store references, per the "Snapshot boundary for list subtrees"
// rule in CLAUDE.md. See `IndexSectionActions` / `SessionSearchFn` in
// `Sources/SessionIndexView.swift` for the reference pattern.

struct ProviderSectionSnapshot {
    let provider: UsageProvider
    let accounts: [ProviderAccount]
    let accountSnapshots: [UUID: ProviderUsageSnapshot]
    let accountErrors: [UUID: String]
    let status: ProviderStatusSnapshot?
}

struct ProviderStatusSnapshot {
    let incidents: [ProviderIncident]
    let isStatusLoaded: Bool
    let isStatusFetchFailed: Bool
    let hasStatusSucceeded: Bool
}

// MARK: - Footer Panel

struct ProviderAccountsFooterPanel: View {
    @ObservedObject private var store = ProviderAccountStore.shared
    @ObservedObject private var controller = ProviderAccountsController.shared
    @ObservedObject private var colorSettings = ProviderUsageColorSettings.shared

    private var providers: [UsageProvider] { ProviderRegistry.ui }

    private var sectionSnapshots: [ProviderSectionSnapshot] {
        let configuredIds = Set(store.accounts.map { $0.providerId })
        return providers
            .filter { configuredIds.contains($0.id) }
            .map { provider in
                let accounts = store.accounts.filter { $0.providerId == provider.id }
                var accountSnapshots: [UUID: ProviderUsageSnapshot] = [:]
                var accountErrors: [UUID: String] = [:]
                for account in accounts {
                    if let snap = controller.snapshots[account.id] {
                        accountSnapshots[account.id] = snap
                    }
                    if let err = controller.fetchErrors[account.id] {
                        accountErrors[account.id] = err
                    }
                }
                let status: ProviderStatusSnapshot? = provider.fetchStatus != nil
                    ? ProviderStatusSnapshot(
                        incidents: controller.incidents[provider.id] ?? [],
                        isStatusLoaded: controller.statusLoaded[provider.id] ?? false,
                        isStatusFetchFailed: controller.statusFetchFailed[provider.id] ?? false,
                        hasStatusSucceeded: controller.statusHasSucceeded[provider.id] ?? false
                    )
                    : nil
                return ProviderSectionSnapshot(
                    provider: provider,
                    accounts: accounts,
                    accountSnapshots: accountSnapshots,
                    accountErrors: accountErrors,
                    status: status
                )
            }
    }

    var body: some View {
        let snapshots = sectionSnapshots
        if snapshots.isEmpty {
            EmptyView()
        } else {
            // `colorSettings` is captured into a local so the per-row closure
            // does not smuggle the store reference into subviews — it only
            // queries the current resolved palette.
            let palette = colorSettings
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshots, id: \.provider.id) { snap in
                    ProviderSection(
                        snapshot: snap,
                        colorFor: { percent in palette.color(for: percent) }
                    ) { isPresented in
                        ProviderAccountsPopover(
                            provider: snap.provider,
                            store: store,
                            controller: controller,
                            isPresented: isPresented
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Provider Section

private struct ProviderSection<PopoverContent: View>: View {
    let snapshot: ProviderSectionSnapshot
    let colorFor: (Int) -> Color
    @ViewBuilder let popoverContent: (Binding<Bool>) -> PopoverContent

    @State private var isPopoverShown = false
    @State private var isCollapsed: Bool

    init(
        snapshot: ProviderSectionSnapshot,
        colorFor: @escaping (Int) -> Color,
        @ViewBuilder popoverContent: @escaping (Binding<Bool>) -> PopoverContent
    ) {
        self.snapshot = snapshot
        self.colorFor = colorFor
        self.popoverContent = popoverContent

        let key = "cmux.providers.accounts.collapsed.\(snapshot.provider.id)"
        _isCollapsed = State(initialValue: UserDefaults.standard.bool(forKey: key))
    }

    private var provider: UsageProvider { snapshot.provider }

    private var collapsedKey: String { "cmux.providers.accounts.collapsed.\(provider.id)" }

    var body: some View {
        // The parent footer only mounts `ProviderSection` for providers with
        // at least one configured account, so the accounts list is guaranteed
        // to be non-empty once this view renders.
        VStack(alignment: .leading, spacing: 4) {
            header
            if !isCollapsed {
                accountsList
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
            popoverContent($isPopoverShown)
        }
    }

    private var header: some View {
        Button {
            toggleCollapsed()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10, alignment: .center)
                Text(provider.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                if let status = snapshot.status {
                    ProviderStatusLabel(status: status)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed
            ? String(localized: "providers.accounts.header.expand", defaultValue: "Expand \(provider.displayName) accounts")
            : String(localized: "providers.accounts.header.collapse", defaultValue: "Collapse \(provider.displayName) accounts")
        )
    }

    private var accountsList: some View {
        // A real `Button` is used so keyboard focus and VoiceOver both treat
        // the stack as an actionable control that opens the detailed popover,
        // not just a mouse-only surface.
        Button {
            isPopoverShown.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.accounts) { account in
                    AccountRow(
                        account: account,
                        snapshot: snapshot.accountSnapshots[account.id],
                        errorMessage: snapshot.accountErrors[account.id],
                        colorFor: colorFor
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "providers.accounts.footer.accessibility", defaultValue: "\(provider.displayName) account usage"))
    }

    private func toggleCollapsed() {
        let newValue = !isCollapsed
        withAnimation(.easeInOut(duration: 0.15)) {
            isCollapsed = newValue
        }
        UserDefaults.standard.set(newValue, forKey: collapsedKey)
    }
}

// MARK: - Provider Status Label (Header)

private struct ProviderStatusLabel: View {
    let status: ProviderStatusSnapshot

    private var providerIncidents: [ProviderIncident] { status.incidents }
    private var isStatusLoaded: Bool { status.isStatusLoaded }
    private var isStatusFetchFailed: Bool { status.isStatusFetchFailed }
    private var hasStatusSucceeded: Bool { status.hasStatusSucceeded }

    var body: some View {
        HStack(spacing: 3) {
            Text("·")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.quaternary)
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .help(tooltipText)
        .accessibilityLabel(statusText)
    }

    private var statusText: String {
        if !isStatusLoaded {
            return String(localized: "provider.status.loading", defaultValue: "…")
        }
        // When the latest status fetch failed, surface that directly rather
        // than falling through to a cached "Operational"/incident reading. A
        // stale snapshot could hide a real outage that landed between polls.
        if isStatusFetchFailed {
            return String(localized: "provider.status.unknown", defaultValue: "Unknown")
        }
        if providerIncidents.isEmpty {
            return String(localized: "provider.status.operational", defaultValue: "Operational")
        }
        return ProviderStatusRanking.statusText(for: providerIncidents)
    }

    private var dotColor: Color {
        if !isStatusLoaded || isStatusFetchFailed {
            return .gray
        }
        if providerIncidents.isEmpty {
            return .green
        }
        return ProviderStatusRanking.dotColor(for: providerIncidents)
    }

    private var tooltipText: String {
        if !isStatusLoaded {
            return String(localized: "providers.accounts.status.loading", defaultValue: "Checking status…")
        }
        // Match the header's failure semantics: when the latest fetch failed,
        // surface that directly rather than reading from a cached snapshot
        // that could hide a real outage landing between polls.
        if isStatusFetchFailed {
            return String(localized: "providers.accounts.status.fetchFailed", defaultValue: "Could not check status")
        }
        if providerIncidents.isEmpty {
            return String(localized: "providers.accounts.status.allOk", defaultValue: "All systems operational")
        }
        if providerIncidents.count == 1, let only = providerIncidents.first {
            return only.name
        }
        let names = providerIncidents.prefix(3).map(\.name).joined(separator: "\n")
        let extra = providerIncidents.count > 3
            ? "\n" + String(localized: "providers.accounts.incidents.truncated", defaultValue: "…")
            : ""
        return names + extra
    }

}

// MARK: - Status Ranking
//
// Real incidents outrank maintenance so a scheduled-maintenance banner never
// masks a concurrent outage on the same provider.
enum ProviderStatusRanking {
    static func impactSeverity(_ impact: String) -> Int {
        switch impact.lowercased() {
        case "critical": return 3
        case "major": return 2
        case "minor": return 1
        case "maintenance": return 0
        default: return -1
        }
    }

    static func worstImpactSeverity(in incidents: [ProviderIncident]) -> Int {
        incidents.map { impactSeverity($0.impact) }.max() ?? -1
    }

    static func worstIncident(in incidents: [ProviderIncident]) -> ProviderIncident? {
        incidents.max { impactSeverity($0.impact) < impactSeverity($1.impact) }
    }

    static func statusText(for incidents: [ProviderIncident]) -> String {
        switch worstImpactSeverity(in: incidents) {
        case 3: return String(localized: "provider.status.critical", defaultValue: "Critical")
        case 2: return String(localized: "provider.status.degraded", defaultValue: "Degraded")
        case 1: return String(localized: "provider.status.minor", defaultValue: "Minor issue")
        case 0: return String(localized: "providers.accounts.status.maintenance", defaultValue: "Maintenance")
        default: return String(localized: "provider.status.operational", defaultValue: "Operational")
        }
    }

    static func dotColor(for incidents: [ProviderIncident]) -> Color {
        switch worstImpactSeverity(in: incidents) {
        case 3: return .red
        case 2: return .orange
        case 1: return .yellow
        case 0: return .blue
        default: return .green
        }
    }
}

// MARK: - Shared label width
//
// "Sess" and "Week" fit in a narrow fixed label column when rendered in
// English, but translations ("Сессия", "Неделя", etc.) can be noticeably
// wider and would either truncate or wrap. The two usage rows in a single
// account card publish their intrinsic label width through this preference
// key; the card takes the max and feeds it back to both rows so they share
// the widest-localized label column and the bar shrinks to fit the rest.
//
// This type is module-internal (not file-private) so that
// `ProviderAccountsPopover.swift` can reuse the same key on its own usage
// rows — both surfaces render "Sess"/"Week" and should share the mechanism.

struct UsageLabelWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Account Row

private struct AccountRow: View {
    let account: ProviderAccount
    let snapshot: ProviderUsageSnapshot?
    let errorMessage: String?
    let colorFor: (Int) -> Color

    @State private var sharedLabelWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .safeHelp(errorMessage)
            } else if let snapshot {
                VStack(spacing: 1) {
                    UsageRow(
                        label: String(localized: "providers.accounts.footer.session", defaultValue: "Sess"),
                        window: snapshot.session,
                        sharedLabelWidth: sharedLabelWidth,
                        percentColor: colorFor(snapshot.session.utilization)
                    )
                    UsageRow(
                        label: String(localized: "providers.accounts.footer.week", defaultValue: "Week"),
                        window: snapshot.week,
                        sharedLabelWidth: sharedLabelWidth,
                        percentColor: colorFor(snapshot.week.utilization)
                    )
                }
                .onPreferenceChange(UsageLabelWidthPreferenceKey.self) { width in
                    sharedLabelWidth = width
                }
            } else {
                Text(String(localized: "providers.accounts.footer.loading", defaultValue: "loading…"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Usage Row

private struct UsageRow: View {
    let label: String
    let window: ProviderUsageWindow
    /// Width that both rows in a single account card share, so the "Sess"
    /// and "Week" labels render at the same width regardless of locale.
    /// Starts at 0; the parent reads the max intrinsic label width via a
    /// preference key and writes it back here.
    let sharedLabelWidth: CGFloat
    /// Pre-resolved color for the percent text and progress-bar fill.
    /// Parent (FooterPanel) owns the `ProviderUsageColorSettings` subscription
    /// so rows below the `ForEach` boundary don't observe stores directly —
    /// see the "Snapshot boundary for list subtrees" rule in CLAUDE.md.
    let percentColor: Color

    private var percent: Int { window.utilization }

    private var pacePercent: Int? {
        guard let resetsAt = window.resetsAt else { return nil }
        guard window.windowSeconds > 0 else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSinceNow)
        let elapsed = max(0, min(window.windowSeconds, window.windowSeconds - remaining))
        return Int((elapsed * 100) / window.windowSeconds)
    }

    private var metaText: String {
        let unavailable = String(
            localized: "providers.accounts.countdown.unavailable",
            defaultValue: "—"
        )
        guard let resetsAt = window.resetsAt else {
            return unavailable
        }
        let interval = resetsAt.timeIntervalSince(Date())
        guard interval > 0 else {
            return unavailable
        }

        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        // Week-scale windows render as `Nd` / `Nd Nh` while at least 24h
        // remain, so the column keeps day-level granularity but still shows
        // the hour remainder (e.g. `2d 22h` vs a misleading flat `2d`).
        // Smaller windows and the final day of a week window surface the
        // hour/minute form so the user can see precision when it matters.
        // Sub-minute remainders render as "<1m" so the countdown keeps a
        // visible value right up to the reset instead of falling to "0m".
        let isMultiDayWindow = window.windowSeconds >= 86_400
        if isMultiDayWindow && hours >= 24 {
            let days = hours / 24
            let remainderHours = hours % 24
            return remainderHours == 0
                ? CountdownUnitFormat.days(days)
                : CountdownUnitFormat.daysHoursSpaced(days: days, hours: remainderHours)
        }
        if hours > 0 {
            return minutes > 0
                ? CountdownUnitFormat.hoursMinutesSpaced(hours: hours, minutes: minutes)
                : CountdownUnitFormat.hours(hours)
        }
        return minutes > 0
            ? CountdownUnitFormat.minutes(minutes)
            : CountdownUnitFormat.lessThanMinute()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: UsageLabelWidthPreferenceKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .frame(
                    width: sharedLabelWidth > 0 ? sharedLabelWidth : nil,
                    alignment: .leading
                )

            Text(String(
                localized: "providers.accounts.usage.percent",
                defaultValue: "\(percent)%"
            ))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(percentColor)
                .frame(width: 28, alignment: .trailing)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.08))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(percentColor.opacity(0.7))
                        .frame(width: max(0, geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100.0))

                    if let pacePercent {
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 1)
                            .offset(x: max(0, min(geometry.size.width - 1, geometry.size.width * CGFloat(pacePercent) / 100.0)))
                    }
                }
            }
            .frame(height: 5)

            Text(metaText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // Width fits the widest compact countdown (`NNh NNm`, `Nd NNh`)
                // rendered at size-9 monospaced without truncation; longer
                // localized strings expand past the minimum via fixedSize.
                .frame(minWidth: 46, alignment: .trailing)
        }
        .safeHelp(tooltipText)
    }

    private var tooltipText: String {
        let percentText = String(
            localized: "providers.accounts.usage.percent",
            defaultValue: "\(percent)%"
        )
        let summary = String(
            localized: "providers.accounts.usage.summary",
            defaultValue: "\(label) \(percentText)"
        )
        // Only present the reset phrase for an upcoming reset. A resetsAt in
        // the past means the server-side window rolled over but we haven't
        // fetched a refresh yet; pairing it with "resets <time>" would imply
        // a future event that has already passed.
        if let resetsAt = window.resetsAt, resetsAt > Date() {
            let resetTime = formatResetTooltip(resetsAt)
            return String(
                localized: "providers.accounts.usage.summaryWithReset",
                defaultValue: "\(summary) · resets \(resetTime)"
            )
        } else if percent == 0 {
            return String(
                localized: "providers.accounts.usage.summaryNotStarted",
                defaultValue: "\(summary) · not started"
            )
        }
        return summary
    }
}

// MARK: - Time Formatting
//
// All reset-time formatters honor the user's current locale so that 12-hour
// regions get "4:00 PM" and non-English locales get localized month names.
// `.autoupdatingCurrent` keeps the formatters in sync with runtime changes to
// the user's locale or 12/24h preference.
// `setLocalizedDateFormatFromTemplate` lets the OS pick the correct ordering
// and separators from the chosen template pieces ("j" = hour in user's
// preferred style, "m" = minute, "MMMd" = abbreviated month + day).

private let resetTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter
}()

private let resetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
}()

private let resetAbsoluteFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
    return formatter
}()

/// Compact reset text for tooltips: "16:00 (in 2h 15m)" or "Apr 25 (in 3d)"
private func formatResetTooltip(_ resetsAt: Date) -> String {
    let interval = resetsAt.timeIntervalSince(Date())
    guard interval > 0 else {
        return resetTimeFormatter.string(from: resetsAt)
    }

    let totalMinutes = Int(interval) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    let anchor: String
    let relative: String
    if hours >= 24 {
        anchor = resetDateFormatter.string(from: resetsAt)
        relative = relativeCountdown(hours: hours)
    } else if hours > 0 {
        anchor = resetTimeFormatter.string(from: resetsAt)
        relative = CountdownUnitFormat.hoursMinutesSpaced(hours: hours, minutes: minutes)
    } else {
        anchor = resetTimeFormatter.string(from: resetsAt)
        relative = CountdownUnitFormat.minutes(max(1, minutes))
    }
    return String(
        localized: "providers.accounts.countdown.tooltip",
        defaultValue: "\(anchor) (in \(relative))"
    )
}

/// Verbose reset text rendered in the hover popover:
/// - "Today 20:00 (2h 15m)" / "Tomorrow 08:00 (14h 5m)" for near resets
/// - "Apr 18, 16:00 (5d 3h)" for far resets
///
/// Module-internal so `ProviderAccountsPopover.swift` can call it directly;
/// the file-private `DateFormatter` instances it references stay captured in
/// this file's scope and are never exposed.
func formatResetVerbose(_ resetsAt: Date) -> String {
    let time = resetTimeFormatter.string(from: resetsAt)
    let calendar = Calendar.current
    let interval = resetsAt.timeIntervalSince(Date())

    let absolute: String
    if calendar.isDateInToday(resetsAt) {
        absolute = String(
            localized: "providers.accounts.popover.todayAtTime",
            defaultValue: "Today \(time)"
        )
    } else if calendar.isDateInTomorrow(resetsAt) {
        absolute = String(
            localized: "providers.accounts.popover.tomorrowAtTime",
            defaultValue: "Tomorrow \(time)"
        )
    } else {
        absolute = resetAbsoluteFormatter.string(from: resetsAt)
    }

    guard interval > 0 else {
        return absolute
    }

    let totalMinutes = Int(interval) / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    let relative: String
    if hours >= 24 {
        relative = relativeCountdown(hours: hours)
    } else if hours > 0 {
        relative = CountdownUnitFormat.hoursMinutesSpaced(hours: hours, minutes: minutes)
    } else {
        relative = minutes > 0
            ? CountdownUnitFormat.minutes(minutes)
            : CountdownUnitFormat.lessThanMinute()
    }
    return String(
        localized: "providers.accounts.countdown.verbose",
        defaultValue: "\(absolute) (\(relative))"
    )
}

/// Builds "Nd Nh" for countdowns longer than a day — showing the hour
/// remainder keeps the label meaningful right up until the reset, rather
/// than collapsing "47h" into a misleading "1d".
private func relativeCountdown(hours: Int) -> String {
    let days = hours / 24
    let remainderHours = hours % 24
    return remainderHours == 0
        ? CountdownUnitFormat.days(days)
        : CountdownUnitFormat.daysHoursSpaced(days: days, hours: remainderHours)
}

/// Localized unit vocabulary for the countdown labels shared by the usage
/// footer, popover, and tooltip. Each phrase is keyed so translators can
/// reshape wording and ordering from `Localizable.xcstrings` without touching
/// view code.
private enum CountdownUnitFormat {
    static func days(_ days: Int) -> String {
        String(
            localized: "providers.accounts.countdown.days",
            defaultValue: "\(days)d"
        )
    }

    static func hours(_ hours: Int) -> String {
        String(
            localized: "providers.accounts.countdown.hours",
            defaultValue: "\(hours)h"
        )
    }

    static func hoursMinutesSpaced(hours: Int, minutes: Int) -> String {
        String(
            localized: "providers.accounts.countdown.hoursMinutesSpaced",
            defaultValue: "\(hours)h \(minutes)m"
        )
    }

    static func daysHoursSpaced(days: Int, hours: Int) -> String {
        String(
            localized: "providers.accounts.countdown.daysHoursSpaced",
            defaultValue: "\(days)d \(hours)h"
        )
    }

    static func minutes(_ minutes: Int) -> String {
        String(
            localized: "providers.accounts.countdown.minutes",
            defaultValue: "\(minutes)m"
        )
    }

    static func lessThanMinute() -> String {
        String(
            localized: "providers.accounts.countdown.lessThanMinute",
            defaultValue: "<1m"
        )
    }
}
