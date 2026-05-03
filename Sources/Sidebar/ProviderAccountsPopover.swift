import AppKit
import SwiftUI

// MARK: - Popover Content

struct ProviderAccountsPopover: View {
    let provider: UsageProvider
    @ObservedObject var store: ProviderAccountStore
    @ObservedObject var controller: ProviderAccountsController
    @Binding var isPresented: Bool

    private var providerAccounts: [ProviderAccount] {
        store.accounts.filter { $0.providerId == provider.id }
    }

    private var providerIncidents: [ProviderIncident] {
        controller.incidents[provider.id] ?? []
    }

    private var isStatusLoaded: Bool {
        controller.statusLoaded[provider.id] ?? false
    }

    private var isStatusFetchFailed: Bool {
        controller.statusFetchFailed[provider.id] ?? false
    }

    private var hasStatusSucceeded: Bool {
        controller.statusHasSucceeded[provider.id] ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountsSection
            if provider.fetchStatus != nil || provider.statusPageURL != nil {
                statusSection
            }
            actionsSection
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 320)
    }

    // MARK: - Accounts Section

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(providerAccounts) { account in
                PopoverAccountDetail(
                    account: account,
                    snapshot: controller.snapshots[account.id],
                    errorMessage: controller.fetchErrors[account.id]
                )
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let statusPageURL = provider.statusPageURL {
                Button {
                    NSWorkspace.shared.open(statusPageURL)
                } label: {
                    HStack(spacing: 4) {
                        Text(provider.statusSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "providers.accounts.status.openPage", defaultValue: "Open status page for \(provider.displayName)"))
            } else {
                Text(provider.statusSectionTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            if provider.fetchStatus == nil {
                EmptyView()
            } else if !isStatusLoaded {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(localized: "providers.accounts.status.loading", defaultValue: "Checking status…"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if isStatusFetchFailed && !hasStatusSucceeded {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(String(localized: "providers.accounts.status.fetchFailed", defaultValue: "Could not check status"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if providerIncidents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(String(localized: "providers.accounts.status.allOk", defaultValue: "All systems operational"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    staleWarningIfNeeded
                }
            } else {
                ForEach(providerIncidents) { incident in
                    IncidentRow(incident: incident)
                }
                staleWarningIfNeeded
            }
        }
    }

    @ViewBuilder
    private var staleWarningIfNeeded: some View {
        if isStatusFetchFailed {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Text(String(localized: "providers.accounts.status.staleWarning", defaultValue: "Status may be outdated"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button {
                controller.refreshNow()
            } label: {
                HStack(spacing: 4) {
                    if controller.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(String(localized: "providers.accounts.refresh.now", defaultValue: "Refresh now"))
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .disabled(controller.isRefreshing)

            Spacer()

            Button {
                isPresented = false
                openProviderAccountsSettings()
            } label: {
                Text(String(localized: "providers.accounts.manage", defaultValue: "Manage accounts…"))
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
    }

    private func openProviderAccountsSettings() {
        SettingsWindowPresenter.show(navigationTarget: .providerAccounts)
    }
}

// MARK: - Popover Account Detail

private struct PopoverAccountDetail: View {
    @ObservedObject private var colorSettings = ProviderUsageColorSettings.shared

    let account: ProviderAccount
    let snapshot: ProviderUsageSnapshot?
    let errorMessage: String?

    @State private var sharedLabelWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.displayName)
                .font(.system(size: 12, weight: .semibold))

            if let errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            } else if let snapshot {
                usageDetails(snapshot: snapshot)
            } else {
                Text(String(localized: "providers.accounts.popover.noData", defaultValue: "—"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func usageDetails(snapshot: ProviderUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            popoverUsageLine(
                label: String(localized: "providers.accounts.footer.session", defaultValue: "Sess"),
                window: snapshot.session,
                isSession: true
            )
            popoverUsageLine(
                label: String(localized: "providers.accounts.footer.week", defaultValue: "Week"),
                window: snapshot.week,
                isSession: false
            )

            Text(String(
                localized: "providers.accounts.popover.fetchedAt.withTime",
                defaultValue: "Updated \(formattedTime(snapshot.fetchedAt))"
            ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .onPreferenceChange(UsageLabelWidthPreferenceKey.self) { width in
            sharedLabelWidth = width
        }
    }

    private func popoverUsageLine(label: String, window: ProviderUsageWindow, isSession: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
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
                defaultValue: "\(window.utilization)%"
            ))
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(colorSettings.color(for: window.utilization))

            popoverResetText(window: window, isSession: isSession)
        }
    }

    private func popoverResetText(window: ProviderUsageWindow, isSession: Bool) -> some View {
        Group {
            switch providerUsageResetLabel(window: window, isSession: isSession) {
            case let .resetsAt(resetsAt):
                Text(String(
                    localized: "providers.accounts.popover.resets.withTime",
                    defaultValue: "Resets \(formatResetVerbose(resetsAt))"
                ))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .awaitingRefresh:
                Text(String(localized: "providers.accounts.usage.awaitingRefresh", defaultValue: "Awaiting refresh"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .sessionNotStarted:
                Text(String(localized: "providers.accounts.usage.sessionNotStarted", defaultValue: "Session not started"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            case .weekResetUnknown:
                Text(String(localized: "providers.accounts.usage.weekResetUnknown", defaultValue: "Reset time unknown"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formattedTime(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }
}

// MARK: - Reset Label Classification

enum ProviderUsageResetLabel: Equatable {
    case resetsAt(Date)
    case awaitingRefresh
    case sessionNotStarted
    case weekResetUnknown
}

// A missing `resetsAt` paired with non-zero utilization is treated as
// stale-data-awaiting-refresh so an active session never reads as "not started".
func providerUsageResetLabel(
    window: ProviderUsageWindow,
    isSession: Bool,
    now: Date = Date()
) -> ProviderUsageResetLabel {
    if let resetsAt = window.resetsAt, resetsAt > now {
        return .resetsAt(resetsAt)
    }
    let hasElapsedReset: Bool = {
        if let resetsAt = window.resetsAt { return resetsAt <= now }
        return window.utilization > 0
    }()
    let isStale = hasElapsedReset && window.utilization > 0
    if isStale {
        return .awaitingRefresh
    }
    if isSession {
        return .sessionNotStarted
    }
    return .weekResetUnknown
}

// MARK: - Incident Row

private struct IncidentRow: View {
    let incident: ProviderIncident

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(impactColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(incident.name)
                    .font(.system(size: 11))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(localizedImpact)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(localizedStatus)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var localizedImpact: String {
        switch incident.impact {
        case "critical": return String(localized: "providers.incident.impact.critical", defaultValue: "Critical")
        case "major": return String(localized: "providers.incident.impact.major", defaultValue: "Major")
        case "minor": return String(localized: "providers.incident.impact.minor", defaultValue: "Minor")
        case "none": return String(localized: "providers.incident.impact.none", defaultValue: "None")
        case "maintenance": return String(localized: "providers.incident.impact.maintenance", defaultValue: "Maintenance")
        default: return String(localized: "providers.incident.impact.unknown", defaultValue: "Unknown")
        }
    }

    private var localizedStatus: String {
        switch incident.status {
        case "investigating": return String(localized: "providers.incident.status.investigating", defaultValue: "Investigating")
        case "identified": return String(localized: "providers.incident.status.identified", defaultValue: "Identified")
        case "monitoring": return String(localized: "providers.incident.status.monitoring", defaultValue: "Monitoring")
        case "scheduled": return String(localized: "providers.incident.status.scheduled", defaultValue: "Scheduled")
        case "in_progress": return String(localized: "providers.incident.status.inProgress", defaultValue: "In progress")
        case "verifying": return String(localized: "providers.incident.status.verifying", defaultValue: "Verifying")
        // Defensive: StatusPage API normally only returns active incidents, but
        // resolved/postmortem may appear if the API changes or during race windows.
        case "resolved": return String(localized: "providers.incident.status.resolved", defaultValue: "Resolved")
        case "postmortem": return String(localized: "providers.incident.status.postmortem", defaultValue: "Postmortem")
        default: return String(localized: "providers.incident.status.unknown", defaultValue: "Unknown")
        }
    }

    private var impactColor: Color {
        switch incident.impact {
        case "critical":
            return .red
        case "major":
            return .orange
        case "minor":
            return .yellow
        case "maintenance":
            return .blue
        default:
            return .gray
        }
    }
}
