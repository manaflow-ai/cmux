public import SwiftUI
public import CmuxSubrouter

/// The compact footer popover: per-provider quick account switching backed
/// by the same store (and the same single mutation path) as the Agents
/// panel.
public struct SubrouterAccountSwitcherPopoverView: View {
    private let store: SubrouterStore

    /// Creates the popover content.
    /// - Parameter store: The app-owned subrouter store.
    public init(store: SubrouterStore) {
        self.store = store
    }

    public var body: some View {
        let snapshot = store.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "subrouter.popover.title", defaultValue: "Agent Accounts"))
                .font(.system(size: 11, weight: .semibold))
            SubrouterDaemonStatusView(
                state: snapshot.daemonState,
                lastErrorDescription: snapshot.lastErrorDescription,
                onRetry: { store.refresh(reason: "retry") }
            )
            if let switchError = store.lastSwitchError {
                Label(switchError.displayMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            ForEach(snapshot.providers, id: \.rawValue) { provider in
                providerPicker(provider: provider, snapshot: snapshot)
            }
            if snapshot.daemonState.isHealthy && snapshot.usageStatuses.isEmpty {
                Text(String(
                    localized: "subrouter.panel.noAccounts",
                    defaultValue: "No accounts configured. Add accounts with the sr CLI."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private func providerPicker(provider: SubrouterProvider, snapshot: SubrouterSnapshot) -> some View {
        let accounts = snapshot.accounts(for: provider)
        // The popover is the quick-switch surface: signed-out accounts are
        // not useful switch targets, so only the active account and healthy
        // candidates appear here. The Agents panel keeps the full list.
        let active = accounts.filter(\.isActive)
        let healthy = accounts.filter { !$0.isActive && !($0.authChecked && !$0.authValid) }
        let usable = active + healthy
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(usable) { account in
                SubrouterPopoverAccountRow(
                    account: account,
                    isSwitchPending: store.pendingSwitchAccountID == account.id,
                    onSwitch: switchAction(for: account)
                )
            }
            if usable.isEmpty && !accounts.isEmpty {
                Text(String(
                    localized: "subrouter.popover.allSignedOut",
                    defaultValue: "All accounts signed out (\(accounts.count))"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func switchAction(for account: SubrouterAccountUsageStatus) -> (() -> Void)? {
        guard !store.configuration.isRemoteEndpoint,
              !account.isActive,
              account.provider.supportsSwitching,
              store.pendingSwitchAccountID == nil else {
            return nil
        }
        let store = store
        return {
            Task { @MainActor in
                // Errors surface through store.lastSwitchError, rendered above.
                try? await store.switchAccount(provider: account.provider, accountID: account.id)
            }
        }
    }
}

/// One compact popover row: active dot, name, cooked chip, switch button.
/// Receives value snapshots plus a closure only.
struct SubrouterPopoverAccountRow: View {
    let account: SubrouterAccountUsageStatus
    let isSwitchPending: Bool
    let onSwitch: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(account.isActive ? Color.green : Color.primary.opacity(0.15))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(account.displayName)
                .font(.system(size: 10, weight: account.isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if let chip = account.quotaAssessment.chipText {
                Text(chip)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if isSwitchPending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
            } else if let onSwitch {
                Button(action: onSwitch) {
                    Text(String(localized: "subrouter.account.switch", defaultValue: "Switch"))
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
    }
}
