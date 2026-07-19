public import SwiftUI
public import CmuxSubrouter

/// One account row: identity, plan tier, active marker, auth validity,
/// cooked chip, usage bars, and a Switch action.
///
/// Receives immutable value snapshots plus closures only (never the store),
/// per the sidebar snapshot-boundary rule.
public struct SubrouterAccountRowView: View {
    private let account: SubrouterAccountUsageStatus
    private let usageHistory: SubrouterUsageHistory
    private let isSwitchPending: Bool
    private let onSwitch: (() -> Void)?

    /// Creates the row.
    /// - Parameters:
    ///   - account: The account snapshot to render.
    ///   - isSwitchPending: Whether a switch to this account is in flight.
    ///   - onSwitch: The switch action, or `nil` when the account is active
    ///     or its provider does not support switching.
    public init(
        account: SubrouterAccountUsageStatus,
        usageHistory: SubrouterUsageHistory = SubrouterUsageHistory(),
        isSwitchPending: Bool,
        onSwitch: (() -> Void)?
    ) {
        self.account = account
        self.usageHistory = usageHistory
        self.isSwitchPending = isSwitchPending
        self.onSwitch = onSwitch
    }

    private var isAuthExpired: Bool {
        account.authChecked && !account.authValid
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                        SubrouterUsageBarView(
                            window: window,
                            historySamples: usageHistory.samples(accountID: account.id, windowName: window.name)
                        )
                    }
                }
                .padding(.leading, 11)
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
            Button(action: onSwitch) {
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
