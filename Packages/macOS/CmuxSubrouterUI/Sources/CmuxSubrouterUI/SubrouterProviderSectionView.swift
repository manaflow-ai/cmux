public import SwiftUI
public import CmuxSubrouter
internal import CmuxAppKitSupportUI
internal import AppKit

/// One provider's section: brand-mark header (the same `AgentIcons`
/// marks Vault uses, with an add-account button when the host can open
/// terminals), account rows, and a signed-out disclosure.
/// Receives value snapshots plus action closures only.
public struct SubrouterProviderSectionView: View {
    private let provider: SubrouterProvider
    private let accounts: [SubrouterAccountUsageStatus]
    private let usageHistory: SubrouterUsageHistory
    private let pendingSwitch: SubrouterPendingSwitch?
    /// Builds the action bundle for one account; the panel owns the
    /// store/terminal wiring so this section stays snapshot-only.
    private let actionsForAccount: (SubrouterAccountUsageStatus) -> SubrouterAccountRowActions
    /// Opens a terminal running the provider's add-account login, or `nil`
    /// when adding is unavailable (remote server mode, unknown provider).
    private let onAddAccount: (() -> Void)?
    /// Signed-out accounts collapse behind a disclosure so a pile of stale
    /// logins (the common long-lived daemon state) never buries the usable
    /// rows. Local UI state only; resets with the panel, which is fine.
    @State private var showsSignedOutAccounts = false

    /// Creates the section.
    /// - Parameters:
    ///   - provider: The provider being rendered.
    ///   - accounts: The provider's account snapshots, in daemon order.
    ///   - pendingSwitch: The provider-scoped identity of an in-flight switch.
    ///   - actionsForAccount: Action-bundle factory for each account row.
    ///   - onAddAccount: The add-account action, or `nil` when unavailable.
    public init(
        provider: SubrouterProvider,
        accounts: [SubrouterAccountUsageStatus],
        usageHistory: SubrouterUsageHistory = SubrouterUsageHistory(),
        pendingSwitch: SubrouterPendingSwitch?,
        actionsForAccount: @escaping (SubrouterAccountUsageStatus) -> SubrouterAccountRowActions,
        onAddAccount: (() -> Void)?
    ) {
        self.provider = provider
        self.accounts = accounts
        self.usageHistory = usageHistory
        self.pendingSwitch = pendingSwitch
        self.actionsForAccount = actionsForAccount
        self.onAddAccount = onAddAccount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                providerIcon
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(accounts.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                if let onAddAccount {
                    Button(action: onAddAccount) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(
                        localized: "subrouter.provider.addAccount",
                        defaultValue: "Add \(provider.displayName) account"
                    ))
                    .accessibilityLabel(String(
                        localized: "subrouter.provider.addAccount",
                        defaultValue: "Add \(provider.displayName) account"
                    ))
                }
            }
            ForEach(usableAccounts) { account in
                SubrouterAccountRowView(
                    account: account,
                    usageHistory: usageHistory,
                    isSwitchPending: pendingSwitch
                        == SubrouterPendingSwitch(provider: account.provider, accountID: account.id),
                    actions: actionsForAccount(account),
                    switchNote: provider.switchSideEffectNote
                )
            }
            if !signedOutAccounts.isEmpty {
                Button {
                    showsSignedOutAccounts.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showsSignedOutAccounts ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                        Text(String(
                            localized: "subrouter.provider.signedOut",
                            defaultValue: "Signed-out accounts (\(signedOutAccounts.count))"
                        ))
                        .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if showsSignedOutAccounts {
                    ForEach(signedOutAccounts) { account in
                        SubrouterAccountRowView(
                            account: account,
                            usageHistory: usageHistory,
                            isSwitchPending: pendingSwitch
                        == SubrouterPendingSwitch(provider: account.provider, accountID: account.id),
                            actions: actionsForAccount(account),
                            switchNote: provider.switchSideEffectNote
                        )
                    }
                }
            }
            if accounts.isEmpty {
                Text(String(
                    localized: "subrouter.provider.noAccounts",
                    defaultValue: "No accounts configured."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                // An empty section's whole point is the add path: offer it
                // as a labeled button, not just the small header "+".
                if let onAddAccount {
                    Button(action: onAddAccount) {
                        Text(String(
                            localized: "subrouter.provider.addAccount",
                            defaultValue: "Add \(provider.displayName) account"
                        ))
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The provider's brand mark from the host app's `AgentIcons` asset
    /// set (the same marks Vault renders), or Vault's generic-agent
    /// fallback for providers without one.
    @ViewBuilder
    private var providerIcon: some View {
        if let assetName = provider.iconAssetName {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                source: .asset(name: assetName, bundle: .main),
                size: NSSize(width: 13, height: 13)
            ))
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 13)
                .accessibilityHidden(true)
        }
    }

    /// The rows shown by default: the active account first, then switchable
    /// healthy accounts ordered most-headroom-first so the best switch
    /// target sits directly under the active row. The active account always
    /// stays visible even when its sign-in expired.
    private var usableAccounts: [SubrouterAccountUsageStatus] {
        let active = accounts.filter(\.isActive)
        let healthy = accounts.filter { !$0.isActive && !($0.authChecked && !$0.authValid) }
        return active + SubrouterAccountUsageStatus.sortedByHeadroom(healthy)
    }

    /// Non-active accounts whose auth check failed; collapsed by default.
    private var signedOutAccounts: [SubrouterAccountUsageStatus] {
        accounts.filter { !$0.isActive && $0.authChecked && !$0.authValid }
    }
}
