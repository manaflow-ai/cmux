public import SwiftUI
public import CmuxSubrouter
internal import AppKit

/// The management actions available on an account row, all optional.
/// Bundled so rows receive one value instead of a closure per verb, per
/// the sidebar snapshot-boundary rule (snapshots + closure bundles only).
public struct SubrouterAccountRowActions {
    /// Switches the provider's active account to this row's account.
    public let onSwitch: (() -> Void)?
    /// Opens a terminal running the provider's login for this account.
    public let onSignIn: (() -> Void)?
    /// Opens a terminal with the remove command pre-typed (not run).
    public let onRemove: (() -> Void)?

    /// Creates the bundle; omit closures for unavailable actions.
    public init(
        onSwitch: (() -> Void)? = nil,
        onSignIn: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.onSwitch = onSwitch
        self.onSignIn = onSignIn
        self.onRemove = onRemove
    }
}

/// One account as a single scannable line — status glyph, name, and a
/// usage summary — that expands in place to the full quota breakdown.
///
/// Follows the standard account-switcher grammar: a checkmark marks the
/// active account (macOS menu convention), every row expands/collapses the
/// same way, switching is a hover-revealed button plus a context-menu verb,
/// and destructive/maintenance verbs live only in the context menu.
///
/// Receives immutable value snapshots plus closures only (never the store),
/// per the sidebar snapshot-boundary rule.
public struct SubrouterAccountRowView: View {
    private let account: SubrouterAccountUsageStatus
    private let usageHistory: SubrouterUsageHistory
    private let isSwitchPending: Bool
    private let actions: SubrouterAccountRowActions
    private let switchNote: String?
    /// Local UI state only; keyed by the `ForEach` account id, so it
    /// survives snapshot refreshes and resets with the panel.
    @State private var isExpanded = false
    @State private var isHovering = false

    /// Creates the row.
    /// - Parameters:
    ///   - account: The account snapshot to render.
    ///   - isSwitchPending: Whether a switch to this account is in flight.
    ///   - actions: The available management actions.
    ///   - switchNote: An optional side-effect note shown as the Switch
    ///     button's tooltip.
    public init(
        account: SubrouterAccountUsageStatus,
        usageHistory: SubrouterUsageHistory = SubrouterUsageHistory(),
        isSwitchPending: Bool,
        actions: SubrouterAccountRowActions = SubrouterAccountRowActions(),
        switchNote: String? = nil
    ) {
        self.account = account
        self.usageHistory = usageHistory
        self.isSwitchPending = isSwitchPending
        self.actions = actions
        self.switchNote = switchNote
    }

    private var isAuthExpired: Bool {
        account.authChecked && !account.authValid
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerLine
            if isExpanded {
                expandedDetails
            }
        }
        .padding(.vertical, 3)
        // Expired accounts stay listed (they are still sign-in and remove
        // targets) but recede so healthy accounts carry the panel.
        .opacity(isAuthExpired ? 0.55 : 1)
        .contextMenu { contextMenuItems }
    }

    // MARK: Header

    private var headerLine: some View {
        HStack(spacing: 5) {
            statusGlyph
                .frame(width: 10)
            Text(account.displayName)
                .font(.system(size: 11, weight: account.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            trailingSummary
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityHeaderLabel)
    }

    /// Checkmark = active (macOS selection convention); warning triangle =
    /// needs a re-login; dim dot otherwise.
    @ViewBuilder
    private var statusGlyph: some View {
        if account.isActive {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SubrouterPalette.accentGradient)
                .accessibilityHidden(true)
        } else if isAuthExpired {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .help(String(
                    localized: "subrouter.account.authInvalid",
                    defaultValue: "Sign-in expired"
                ))
        } else {
            Circle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }

    /// The trailing summary: a pending spinner, the hover-revealed Switch
    /// button, a cooked chip when the account is quota-limited, or the
    /// constraining window's mini gauge.
    @ViewBuilder
    private var trailingSummary: some View {
        let assessment = account.quotaAssessment
        if isSwitchPending {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if isHovering, let onSwitch = actions.onSwitch {
            let button = Button(action: onSwitch) {
                Text(String(localized: "subrouter.account.switch", defaultValue: "Switch"))
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityLabel(String(
                localized: "subrouter.account.switchTo",
                defaultValue: "Switch to \(account.displayName)"
            ))
            if let switchNote {
                button.help(switchNote)
            } else {
                button
            }
        } else if let chip = assessment.chipText {
            Text(chip)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chipColor(for: assessment))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(chipColor(for: assessment).opacity(0.15), in: Capsule())
        } else if let window = account.constrainingWindow {
            miniGauge(for: window)
            Text(String(
                localized: "subrouter.usage.percentUsed",
                defaultValue: "\(Int(window.clampedUsedPercent.rounded()))%"
            ))
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(SubrouterPalette.usageAccent(for: window.clampedUsedPercent))
        } else if account.errorDescription?.isEmpty == false && !isAuthExpired {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
                .help(account.errorDescription ?? "")
        }
    }

    // MARK: Expanded details

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailStatusLine
            if let detail = account.quotaAssessment.detailText {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                SubrouterUsageBarView(
                    window: window,
                    historySamples: usageHistory.samples(
                        provider: account.provider,
                        accountID: account.id,
                        windowName: window.name
                    )
                )
            }
            if account.windows.isEmpty {
                Text(String(
                    localized: "subrouter.account.noUsageData",
                    defaultValue: "No usage data."
                ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 15)
    }

    /// Plan tier, credits, and any fetch-error summary — the identity
    /// details that used to crowd the header.
    @ViewBuilder
    private var detailStatusLine: some View {
        HStack(spacing: 5) {
            if let planType = account.planType, !planType.isEmpty {
                Text(planType)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            if let credits = account.credits, credits.hasCredits, !credits.balance.isEmpty {
                Text(credits.balance)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let errorDescription = account.errorDescription, !errorDescription.isEmpty {
                Label(
                    String(localized: "subrouter.account.usageUnavailable", defaultValue: "Usage unavailable"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(errorDescription)
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if let onSwitch = actions.onSwitch, !isSwitchPending {
            Button(String(
                localized: "subrouter.account.switchTo",
                defaultValue: "Switch to \(account.displayName)"
            )) {
                onSwitch()
            }
        }
        if let onSignIn = actions.onSignIn {
            Button(String(
                localized: "subrouter.account.signInAgain",
                defaultValue: "Sign In Again…"
            )) {
                onSignIn()
            }
        }
        Button(String(
            localized: "subrouter.account.copyID",
            defaultValue: "Copy Account ID"
        )) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(account.id, forType: .string)
        }
        if let onRemove = actions.onRemove {
            Divider()
            Button(String(
                localized: "subrouter.account.removeAccount",
                defaultValue: "Remove Account…"
            ), role: .destructive) {
                onRemove()
            }
        }
    }

    // MARK: Shared bits

    private func miniGauge(for window: SubrouterUsageWindow) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(SubrouterPalette.usageFill(for: window.clampedUsedPercent))
                .frame(width: max(2, 44 * window.clampedUsedPercent / 100))
        }
        .frame(width: 44, height: 4)
        .accessibilityHidden(true)
    }

    private func chipColor(for assessment: SubrouterQuotaAssessment) -> Color {
        switch assessment {
        case .cooked: return .red
        case .tempCooked: return .orange
        case .ok: return .secondary
        }
    }

    private var accessibilityHeaderLabel: String {
        var parts = [account.displayName]
        if account.isActive {
            parts.append(String(localized: "subrouter.account.active", defaultValue: "Active"))
        }
        if isAuthExpired {
            parts.append(String(localized: "subrouter.account.authInvalid", defaultValue: "Sign-in expired"))
        } else if let window = account.constrainingWindow {
            parts.append(String(
                localized: "subrouter.usage.accessibility",
                defaultValue: "\(window.displayLabel): \(Int(window.clampedUsedPercent.rounded())) percent used"
            ))
        }
        return parts.joined(separator: ", ")
    }
}
