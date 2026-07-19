public import SwiftUI
public import CmuxSubrouter

/// One provider's section: header, optional switch side-effect note, and
/// account rows. Receives value snapshots plus an action closure only.
public struct SubrouterProviderSectionView: View {
    private let provider: SubrouterProvider
    private let accounts: [SubrouterAccountUsageStatus]
    private let pendingSwitchAccountID: String?
    /// `nil` disables switching entirely (remote-server mode).
    private let onSwitch: ((SubrouterAccountUsageStatus) -> Void)?
    /// Signed-out accounts collapse behind a disclosure so a pile of stale
    /// logins (the common long-lived daemon state) never buries the usable
    /// rows. Local UI state only; resets with the panel, which is fine.
    @State private var showsSignedOutAccounts = false

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
        onSwitch: ((SubrouterAccountUsageStatus) -> Void)?
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
            if onSwitch != nil, let note = provider.switchSideEffectNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            ForEach(usableAccounts) { account in
                SubrouterAccountRowView(
                    account: account,
                    isSwitchPending: pendingSwitchAccountID == account.id,
                    onSwitch: switchAction(for: account)
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
                            isSwitchPending: pendingSwitchAccountID == account.id,
                            onSwitch: switchAction(for: account)
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
            }
        }
    }

    /// The rows shown by default: the active account first, then switchable
    /// healthy accounts, each group keeping the daemon's order. The active
    /// account always stays visible even when its sign-in expired.
    private var usableAccounts: [SubrouterAccountUsageStatus] {
        let active = accounts.filter(\.isActive)
        let healthy = accounts.filter { !$0.isActive && !($0.authChecked && !$0.authValid) }
        return active + healthy
    }

    /// Non-active accounts whose auth check failed; collapsed by default.
    private var signedOutAccounts: [SubrouterAccountUsageStatus] {
        accounts.filter { !$0.isActive && $0.authChecked && !$0.authValid }
    }

    private func switchAction(for account: SubrouterAccountUsageStatus) -> (() -> Void)? {
        guard let onSwitch,
              !account.isActive,
              provider.supportsSwitching,
              pendingSwitchAccountID == nil else {
            return nil
        }
        return { onSwitch(account) }
    }
}
