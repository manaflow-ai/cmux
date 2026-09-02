public import SwiftUI
public import CmuxSubrouter
internal import AppKit

/// The management actions available on an account row, all optional.
/// Bundled so rows receive one value instead of a closure per verb, per
/// the sidebar snapshot-boundary rule (snapshots + closure bundles only).
public struct SubrouterAccountRowActions {
    /// Switches the provider's active account to this row's account.
    public let onSwitch: (() -> Void)?
    /// Opens a terminal with the remove command pre-typed (not run).
    public let onRemove: (() -> Void)?

    /// Creates the bundle; omit closures for unavailable actions.
    public init(
        onSwitch: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.onSwitch = onSwitch
        self.onRemove = onRemove
    }
}

/// One account as a single scannable line — status glyph, name, and a
/// usage summary — that expands in place to the full quota breakdown.
///
/// Follows the standard account-switcher grammar: a checkmark marks the
/// active account (macOS menu convention), every row expands/collapses the
/// same way, and destructive/maintenance verbs live only in the context
/// menu. Switching is always visible: a switchable row's status glyph is a
/// radio-style button (click to switch), with the hover-revealed Switch
/// button and context-menu verb as equivalent paths.
///
/// Receives immutable value snapshots plus closures only (never the store),
/// per the sidebar snapshot-boundary rule.
public struct SubrouterAccountRowView: View {
    private let account: SubrouterAccountUsageStatus
    private let isSwitchPending: Bool
    private let actions: SubrouterAccountRowActions
    private let switchNote: String?
    private let showsSelectionState: Bool
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
    ///   - showsSelectionState: Whether the active checkmark and radio
    ///     switch glyph render. Off for remote pools, where the daemon
    ///     load-balances accounts per session and marking one "active"
    ///     would misread as a selection.
    public init(
        account: SubrouterAccountUsageStatus,
        isSwitchPending: Bool,
        actions: SubrouterAccountRowActions = SubrouterAccountRowActions(),
        switchNote: String? = nil,
        showsSelectionState: Bool = true
    ) {
        self.account = account
        self.isSwitchPending = isSwitchPending
        self.actions = actions
        self.switchNote = switchNote
        self.showsSelectionState = showsSelectionState
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
        // Expired accounts stay listed as remove/diagnostic targets but recede
        // so healthy accounts carry the panel.
        .opacity(isAuthExpired ? 0.55 : 1)
        .contextMenu { contextMenuItems }
    }

    // MARK: Header

    private var headerLine: some View {
        HStack(spacing: 5) {
            // In selection mode every row reserves the glyph column so
            // names align under the checkmark. Without selection state the
            // column disappears entirely (uniform pool rows); only the
            // expired warning still claims it.
            if showsSelectionState || isAuthExpired {
                statusGlyph
                    .frame(width: 10)
            }
            // Only the chevron toggles expansion: a whole-row tap target
            // turned every stray click into an expand, and SwiftUI's
            // parent-gesture-vs-nested-button click routing has changed
            // across macOS majors, so the controls (radio glyph, Switch
            // button) must own their clicks anyway.
            Text(account.displayName)
                .font(.system(
                    size: 11,
                    weight: showsSelectionState && account.isActive ? .semibold : .regular
                ))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            trailingSummary
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                // The disclosure is row furniture, not data: recede until
                // the pointer arrives (or the row is open).
                .opacity(isHovering || isExpanded ? 1 : 0.35)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .contentShape(Rectangle().inset(by: -6))
                .onTapGesture { isExpanded.toggle() }
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityHeaderLabel)
        .accessibilityAction { isExpanded.toggle() }
    }

    /// Checkmark = active (macOS selection convention); warning triangle =
    /// needs a re-login; otherwise a radio-style dot that switches to this
    /// account on click when switching is available (dim inert dot when not).
    @ViewBuilder
    private var statusGlyph: some View {
        if showsSelectionState && account.isActive {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SubrouterPalette.blue)
                .accessibilityHidden(true)
        } else if isAuthExpired {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .help(String(
                    localized: "subrouter.account.authInvalid",
                    defaultValue: "Sign-in expired"
                ))
        } else if let onSwitch = actions.onSwitch, !isSwitchPending {
            Button(action: onSwitch) {
                Circle()
                    .strokeBorder(
                        isHovering ? SubrouterPalette.blue : Color.primary.opacity(0.3),
                        lineWidth: 1
                    )
                    .frame(width: 7, height: 7)
                    .contentShape(Circle().inset(by: -3))
            }
            .buttonStyle(.plain)
            .help(String(
                localized: "subrouter.account.switchTo",
                defaultValue: "Switch to \(account.displayName)"
            ))
            .accessibilityLabel(String(
                localized: "subrouter.account.switchTo",
                defaultValue: "Switch to \(account.displayName)"
            ))
        } else {
            Circle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }

    /// The trailing summary: a pending spinner, the hover-revealed Switch
    /// button, or the uniform gauge summary (percent, or reset countdown
    /// once the account is exhausted).
    @ViewBuilder
    private var trailingSummary: some View {
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
        } else if account.constrainingWindow != nil {
            SubrouterUsageSummaryView(account: account)
        } else if account.errorDescription?.isEmpty == false && !isAuthExpired {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
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
                SubrouterUsageBarView(window: window)
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

    /// Credits and any fetch-error summary. The plan-tier chip is gone:
    /// it repeated the same value on nearly every row without informing
    /// any decision.
    @ViewBuilder
    private var detailStatusLine: some View {
        HStack(spacing: 5) {
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
                .foregroundStyle(.secondary)
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

    private var accessibilityHeaderLabel: String {
        var parts = [account.displayName]
        if showsSelectionState && account.isActive {
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
