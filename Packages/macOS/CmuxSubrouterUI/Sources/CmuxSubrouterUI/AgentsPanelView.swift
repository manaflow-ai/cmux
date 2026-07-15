public import SwiftUI
public import CmuxSubrouter

/// The right-sidebar Agents panel: daemon status, per-provider account
/// sections with usage bars and Switch actions, and live session pins.
///
/// Holds the `@Observable` store at the top; everything below the section
/// boundary receives value snapshots plus closures only. Visibility drives
/// the store's poll gating via `onAppear`/`onDisappear`.
public struct AgentsPanelView: View {
    private let store: SubrouterStore

    /// Creates the panel.
    /// - Parameter store: The app-owned subrouter store.
    public init(store: SubrouterStore) {
        self.store = store
    }

    public var body: some View {
        let snapshot = store.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SubrouterDaemonStatusView(
                    state: snapshot.daemonState,
                    lastErrorDescription: snapshot.lastErrorDescription,
                    onRetry: { store.refresh(reason: "retry") }
                )
                if let switchError = store.lastSwitchError {
                    switchErrorBanner(switchError)
                }
                ForEach(snapshot.providers, id: \.rawValue) { provider in
                    SubrouterProviderSectionView(
                        provider: provider,
                        accounts: snapshot.accounts(for: provider),
                        pendingSwitchAccountID: store.pendingSwitchAccountID,
                        onSwitch: { account in
                            switchAccount(account)
                        }
                    )
                }
                if snapshot.daemonState.isHealthy && snapshot.usageStatuses.isEmpty {
                    Text(String(
                        localized: "subrouter.panel.noAccounts",
                        defaultValue: "No accounts configured. Add accounts with the sr CLI."
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                if !snapshot.sessions.isEmpty {
                    SubrouterSessionsSectionView(sessions: snapshot.sessions)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.setSurfaceVisible(.agentsPanel, true) }
        .onDisappear { store.setSurfaceVisible(.agentsPanel, false) }
        .accessibilityIdentifier("SubrouterAgentsPanel")
    }

    private func switchAccount(_ account: SubrouterAccountUsageStatus) {
        let store = store
        Task { @MainActor in
            // Errors surface through store.lastSwitchError, rendered above.
            try? await store.switchAccount(provider: account.provider, accountID: account.id)
        }
    }

    private func switchErrorBanner(_ error: SubrouterSwitchError) -> some View {
        Label(error.displayMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
