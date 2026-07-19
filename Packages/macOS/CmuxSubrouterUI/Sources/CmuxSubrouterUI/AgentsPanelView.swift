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
        let configuration = store.configuration
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SubrouterDaemonStatusView(
                    state: snapshot.daemonState,
                    lastErrorDescription: snapshot.lastErrorDescription,
                    onRetry: { store.refresh(reason: "retry") }
                )
                if configuration.isRemoteEndpoint {
                    remoteServerNote(configuration: configuration)
                }
                if let switchError = store.lastSwitchError {
                    switchErrorBanner(switchError)
                }
                ForEach(snapshot.providers, id: \.rawValue) { provider in
                    SubrouterProviderSectionView(
                        provider: provider,
                        accounts: snapshot.accounts(for: provider),
                        usageHistory: store.usageHistory,
                        pendingSwitchAccountID: store.pendingSwitchAccountID,
                        // Remote servers assign accounts per session; there
                        // is no global switch to offer.
                        onSwitch: configuration.isRemoteEndpoint ? nil : { account in
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
                SubrouterActivityChartView(
                    activity: SubrouterSessionStats.accountActivity(
                        sessions: snapshot.sessions,
                        window: SubrouterActivityChartView.window,
                        now: Date()
                    )
                )
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

    private func remoteServerNote(configuration: SubrouterConfiguration) -> some View {
        let name = configuration.serverName ?? configuration.endpoint.baseURL.host() ?? ""
        return Label {
            Text(String(
                localized: "subrouter.panel.remoteServer",
                defaultValue: "Watching server \(name). It assigns accounts to each session automatically."
            ))
        } icon: {
            Image(systemName: "server.rack")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
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
