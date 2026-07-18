public import SwiftUI
public import CmuxSubrouter

/// One provider's section: header, optional switch side-effect note, and
/// account rows. Receives value snapshots plus an action closure only.
public struct SubrouterProviderSectionView: View {
    private let provider: SubrouterProvider
    private let accounts: [SubrouterAccountUsageStatus]
    private let pendingSwitchAccountID: String?
    private let onSwitch: (SubrouterAccountUsageStatus) -> Void

    /// Creates the section.
    /// - Parameters:
    ///   - provider: The provider being rendered.
    ///   - accounts: The provider's account snapshots, in daemon order.
    ///   - pendingSwitchAccountID: The account id of an in-flight switch.
    ///   - onSwitch: Called with the account the user asked to switch to.
    public init(
        provider: SubrouterProvider,
        accounts: [SubrouterAccountUsageStatus],
        pendingSwitchAccountID: String?,
        onSwitch: @escaping (SubrouterAccountUsageStatus) -> Void
    ) {
        self.provider = provider
        self.accounts = accounts
        self.pendingSwitchAccountID = pendingSwitchAccountID
        self.onSwitch = onSwitch
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let note = provider.switchSideEffectNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            ForEach(displayAccounts) { account in
                SubrouterAccountRowView(
                    account: account,
                    isSwitchPending: pendingSwitchAccountID == account.id,
                    onSwitch: switchAction(for: account)
                )
            }
            if accounts.isEmpty {
                Text(String(
                    localized: "subrouter.provider.noAccounts",
                    defaultValue: "No accounts configured."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// Display order: the active account first, then switchable healthy
    /// accounts, with sign-in-expired accounts last — each group keeping the
    /// daemon's order. Keeps the useful rows above the fold when many stale
    /// accounts linger.
    private var displayAccounts: [SubrouterAccountUsageStatus] {
        let active = accounts.filter(\.isActive)
        let healthy = accounts.filter { !$0.isActive && !($0.authChecked && !$0.authValid) }
        let expired = accounts.filter { !$0.isActive && $0.authChecked && !$0.authValid }
        return active + healthy + expired
    }

    private func switchAction(for account: SubrouterAccountUsageStatus) -> (() -> Void)? {
        guard !account.isActive,
              provider.supportsSwitching,
              pendingSwitchAccountID == nil else {
            return nil
        }
        return { onSwitch(account) }
    }
}
