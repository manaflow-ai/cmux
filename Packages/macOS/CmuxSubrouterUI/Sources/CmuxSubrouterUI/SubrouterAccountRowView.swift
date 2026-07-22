public import SwiftUI
public import CmuxSubrouter

/// One account row: identity, plan tier, active marker, auth validity,
/// cooked chip, usage, and a Switch action.
///
/// The active account is the panel's anchor and always shows its full
/// per-window breakdown. Every other account collapses to a one-line
/// summary of its constraining window (the one that will limit it first)
/// and expands on click — this keeps a many-account panel scannable.
///
/// Receives immutable value snapshots plus closures only (never the store),
/// per the sidebar snapshot-boundary rule.
public struct SubrouterAccountRowView: View {
    private let account: SubrouterAccountUsageStatus
    private let usageHistory: SubrouterUsageHistory
    private let isSwitchPending: Bool
    private let onSwitch: (() -> Void)?
    private let switchNote: String?
    /// Local UI state only; keyed by the `ForEach` account id, so it
    /// survives snapshot refreshes and resets with the panel.
    @State private var isExpanded = false

    /// Creates the row.
    /// - Parameters:
    ///   - account: The account snapshot to render.
    ///   - isSwitchPending: Whether a switch to this account is in flight.
    ///   - onSwitch: The switch action, or `nil` when the account is active
    ///     or its provider does not support switching.
    ///   - switchNote: An optional side-effect note shown as the Switch
    ///     button's tooltip.
    public init(
        account: SubrouterAccountUsageStatus,
        usageHistory: SubrouterUsageHistory = SubrouterUsageHistory(),
        isSwitchPending: Bool,
        onSwitch: (() -> Void)?,
        switchNote: String? = nil
    ) {
        self.account = account
        self.usageHistory = usageHistory
        self.isSwitchPending = isSwitchPending
        self.onSwitch = onSwitch
        self.switchNote = switchNote
    }

    private var isAuthExpired: Bool {
        account.authChecked && !account.authValid
    }

    private var showsFullWindows: Bool {
        account.isActive || isExpanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(account.isActive ? Color.green : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(account.displayName)
                    .font(.system(size: 11, weight: account.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let planType = account.planType, !planType.isEmpty {
                    Text(planType)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 4)
                trailingControl
            }
            statusLine
            if !account.windows.isEmpty {
                if showsFullWindows {
                    fullWindowList
                } else {
                    compactUsageToggle
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, account.isActive ? 7 : 0)
        // The active account is the panel's anchor; give it a subtle card.
        .background(
            account.isActive ? Color.green.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        // Expired accounts stay listed (they are still switch targets after
        // a re-login) but recede so healthy accounts carry the panel.
        .opacity(isAuthExpired ? 0.6 : 1)
    }

    @ViewBuilder
    private var fullWindowList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !account.isActive {
                collapseToggle
            }
            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                SubrouterUsageBarView(
                    window: window,
                    historySamples: usageHistory.samples(accountID: account.id, windowName: window.name)
                )
            }
        }
        .padding(.leading, 11)
    }

    /// The collapsed one-line summary: the constraining window's label, a
    /// mini gauge, and its used percentage. Clicking expands the full
    /// per-window breakdown.
    @ViewBuilder
    private var compactUsageToggle: some View {
        if let window = account.constrainingWindow {
            Button {
                isExpanded = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(window.displayLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    miniGauge(for: window)
                    Text(String(
                        localized: "subrouter.usage.percentUsed",
                        defaultValue: "\(Int(window.clampedUsedPercent.rounded()))%"
                    ))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(usageColor(for: window.clampedUsedPercent))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 11)
            .accessibilityLabel(String(
                localized: "subrouter.account.showUsageDetails",
                defaultValue: "Show usage details for \(account.displayName)"
            ))
        }
    }

    private var collapseToggle: some View {
        Button {
            isExpanded = false
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                Text(String(
                    localized: "subrouter.account.hideUsageDetails",
                    defaultValue: "Hide details"
                ))
                .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }

    private func miniGauge(for window: SubrouterUsageWindow) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(usageColor(for: window.clampedUsedPercent))
                .frame(width: max(2, 44 * window.clampedUsedPercent / 100))
        }
        .frame(width: 44, height: 4)
        .accessibilityHidden(true)
    }

    /// Severity thresholds match `SubrouterUsageBarView` and the `sr` CLI.
    private func usageColor(for usedPercent: Double) -> Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        return .green
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isSwitchPending {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if account.isActive {
            Text(String(localized: "subrouter.account.active", defaultValue: "Active"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.green)
        } else if let onSwitch {
            let button = Button(action: onSwitch) {
                Text(String(localized: "subrouter.account.switch", defaultValue: "Switch"))
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(
                String(
                    localized: "subrouter.account.switchTo",
                    defaultValue: "Switch to \(account.displayName)"
                )
            )
            if let switchNote {
                button.help(switchNote)
            } else {
                button
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let assessment = account.quotaAssessment
        HStack(spacing: 5) {
            // Raw daemon/refresh error text stays out of the row; the short
            // localized label carries the state and the tooltip the detail.
            if isAuthExpired {
                Label(
                    String(localized: "subrouter.account.authInvalid", defaultValue: "Sign-in expired"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(account.errorDescription ?? "")
            } else if let errorDescription = account.errorDescription, !errorDescription.isEmpty {
                Label(
                    String(localized: "subrouter.account.usageUnavailable", defaultValue: "Usage unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(errorDescription)
            }
            if let chip = assessment.chipText {
                Text(chip)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(chipColor(for: assessment))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(chipColor(for: assessment).opacity(0.15), in: Capsule())
            }
            if let credits = account.credits, credits.hasCredits, !credits.balance.isEmpty {
                Text(credits.balance)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 11)
        if let detail = assessment.detailText {
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.leading, 11)
        }
    }

    private func chipColor(for assessment: SubrouterQuotaAssessment) -> Color {
        switch assessment {
        case .cooked: return .red
        case .tempCooked: return .orange
        case .ok: return .secondary
        }
    }
}
