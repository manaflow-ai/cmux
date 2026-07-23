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
    private let isPanelVisible: Bool
    private let onVisibilityChange: (Bool) -> Void
    /// Opens a terminal for an `sr` maintenance command (add account,
    /// re-login, remove). `nil` hides those actions entirely — hosts that
    /// cannot create workspaces (previews, tests) pass nothing.
    private let onOpenTerminal: ((SubrouterTerminalRequest) -> Void)?
    @State private var isRegisteredVisible = false

    /// Creates the panel.
    /// - Parameters:
    ///   - store: The app-owned subrouter store.
    ///   - isPanelVisible: Whether the hosting sidebar is actually on
    ///     screen. Hosts that keep hidden content mounted (the right
    ///     sidebar shell never unmounts once shown) must pass their real
    ///     visibility here so polling stops while the panel is hidden.
    ///   - onVisibilityChange: Balanced per-instance visibility
    ///     transitions (`true` then `false`, never repeated). The host
    ///     must reference-count these into the store's `.agentsPanel`
    ///     surface: several windows can each show a panel against the one
    ///     shared store, so no instance may write the shared bit directly.
    public init(
        store: SubrouterStore,
        isPanelVisible: Bool = true,
        onVisibilityChange: @escaping (Bool) -> Void,
        onOpenTerminal: ((SubrouterTerminalRequest) -> Void)? = nil
    ) {
        self.store = store
        self.isPanelVisible = isPanelVisible
        self.onVisibilityChange = onVisibilityChange
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        let snapshot = store.snapshot
        let configuration = store.configuration
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SubrouterDaemonStatusView(
                    state: snapshot.daemonState,
                    lastErrorDescription: snapshot.lastErrorDescription,
                    hasData: !snapshot.usageStatuses.isEmpty,
                    isRemoteEndpoint: configuration.isRemoteEndpoint,
                    serverName: configuration.serverName
                        ?? configuration.endpoint.baseURL.host(),
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
                        pendingSwitch: store.pendingSwitch,
                        actionsForAccount: { account in
                            rowActions(account: account, configuration: configuration)
                        },
                        onAddAccount: terminalAction(
                            configuration.isRemoteEndpoint ? nil : .addAccount(provider: provider)
                        )
                    )
                }
                if snapshot.daemonState.isHealthy && snapshot.usageStatuses.isEmpty {
                    emptyAccountsState(configuration: configuration)
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
        .onAppear { updateVisibilityRegistration(isPanelVisible) }
        .onDisappear { updateVisibilityRegistration(false) }
        .onChange(of: isPanelVisible) { _, visible in
            updateVisibilityRegistration(visible)
        }
        .accessibilityIdentifier("SubrouterAgentsPanel")
    }

    /// Forwards deduplicated show/hide transitions to the host, so its
    /// reference count stays balanced no matter how appear/disappear and
    /// visibility changes interleave.
    private func updateVisibilityRegistration(_ visible: Bool) {
        guard visible != isRegisteredVisible else { return }
        isRegisteredVisible = visible
        onVisibilityChange(visible)
    }

    private func switchAccount(_ account: SubrouterAccountUsageStatus) {
        let store = store
        Task { @MainActor in
            // Errors surface through store.lastSwitchError, rendered above.
            try? await store.switchAccount(provider: account.provider, accountID: account.id)
        }
    }

    /// The action bundle for one account row. Switching stays local-only
    /// (remote servers assign accounts per session); sign-in and remove
    /// manage the local `sr` store, so they follow the same gate — and all
    /// terminal-backed verbs also require a terminal-capable host.
    private func rowActions(
        account: SubrouterAccountUsageStatus,
        configuration: SubrouterConfiguration
    ) -> SubrouterAccountRowActions {
        guard !configuration.isRemoteEndpoint else {
            return SubrouterAccountRowActions()
        }
        // Matches the popover's filter: a row whose auth check failed is a
        // sign-in candidate, not a switch target — activating it would
        // replace working credentials with an expired account.
        let canSwitch = !account.isActive
            && account.provider.supportsSwitching
            && (!account.authChecked || account.authValid)
            && store.pendingSwitch == nil
        return SubrouterAccountRowActions(
            onSwitch: canSwitch ? { switchAccount(account) } : nil,
            onSignIn: terminalAction(.signIn(account: account)),
            onRemove: terminalAction(.removeAccount(account: account))
        )
    }

    /// Wraps a terminal request in a closure for the host, or `nil` when
    /// the request is unsupported or no terminal host is wired.
    private func terminalAction(_ request: SubrouterTerminalRequest?) -> (() -> Void)? {
        guard let onOpenTerminal, let request else { return nil }
        return { onOpenTerminal(request) }
    }

    /// The zero-accounts state: explanatory text, plus one-click add
    /// buttons when the host can open terminals against the local `sr`.
    @ViewBuilder
    private func emptyAccountsState(configuration: SubrouterConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "subrouter.panel.noAccounts",
                defaultValue: "No accounts configured. Add accounts with the sr CLI."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            if !configuration.isRemoteEndpoint {
                HStack(spacing: 6) {
                    ForEach([SubrouterProvider.codex, .claude], id: \.rawValue) { provider in
                        if let action = terminalAction(.addAccount(provider: provider)) {
                            Button(action: action) {
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
            }
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
