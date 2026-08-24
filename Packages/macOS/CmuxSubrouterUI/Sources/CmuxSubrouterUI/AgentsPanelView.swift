public import SwiftUI
public import CmuxSubrouter

/// The right-sidebar Agents panel: daemon status and per-provider account
/// sections with usage bars and Switch actions.
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
        let accountTarget = configuration.accountTarget
        ScrollView {
            // Sections sit flat on the panel (no card boxes), so the gap
            // between providers is the only separator — keep it generous.
            VStack(alignment: .leading, spacing: 14) {
                SubrouterDaemonStatusView(
                    state: snapshot.daemonState,
                    lastErrorDescription: snapshot.lastErrorDescription,
                    hasData: !snapshot.usageStatuses.isEmpty,
                    isRemoteEndpoint: configuration.isRemoteEndpoint,
                    serverName: configuration.serverName
                        ?? configuration.endpoint.baseURL.host(),
                    onRetry: { store.refresh(reason: "retry") },
                    onSetup: configuration.isRemoteEndpoint
                        ? nil
                        : terminalAction(.setup()),
                    onConnectServer: configuration.isRemoteEndpoint
                        ? nil
                        : terminalAction(.connectServer())
                )
                if let switchError = store.lastSwitchError {
                    switchErrorBanner(switchError)
                }
                ForEach(snapshot.sectionProviders, id: \.rawValue) { provider in
                    SubrouterProviderSectionView(
                        provider: provider,
                        accounts: snapshot.accounts(for: provider),
                        pendingSwitch: store.pendingSwitch,
                        actionsForAccount: { account in
                            rowActions(
                                account: account,
                                configuration: configuration,
                                accountTarget: accountTarget
                            )
                        },
                        // A named remote target gets a direct server-scoped
                        // login; an unnamed explicit URL stays read-only.
                        onAddAccount: accountTarget.flatMap { target in
                            terminalAction(.addAccount(provider: provider, target: target))
                        },
                        // A remote pool is load-balanced per session: no
                        // account is "the selected one", so rows carry no
                        // checkmark or switch glyph there.
                        showsSelectionState: !configuration.isRemoteEndpoint
                    )
                }
            }
            // 12pt matches the other right-sidebar tabs' content inset
            // (Vault section headers, Files rows), so switching tabs does
            // not shift the left edge.
            .padding(.horizontal, 12)
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

    /// The action bundle for one account row. Remote pools get no row
    /// actions: the daemon load-balances accounts per session, so the UI
    /// never presents one as selected or switchable (hosted pools choose an
    /// account per session, so global switching is unavailable). Sign-in and
    /// remove manage the local `sr` store, so
    /// they are local-only too — and all terminal-backed verbs also
    /// require a terminal-capable host.
    private func rowActions(
        account: SubrouterAccountUsageStatus,
        configuration: SubrouterConfiguration,
        accountTarget: SubrouterAccountTarget?
    ) -> SubrouterAccountRowActions {
        guard !configuration.isRemoteEndpoint else {
            return SubrouterAccountRowActions()
        }
        // Matches the popover's filter: a row whose auth check failed is a
        // sign-in candidate, not a switch target — activating it would
        // replace working credentials with an expired account.
        let canSwitch = !account.isActive
            && account.isSwitchableCandidate
            && store.pendingSwitch == nil
        return SubrouterAccountRowActions(
            onSwitch: canSwitch ? { switchAccount(account) } : nil,
            onSignIn: accountTarget.flatMap { target in
                terminalAction(.signIn(account: account, target: target))
            },
            onRemove: accountTarget.flatMap { target in
                terminalAction(.removeAccount(account: account, target: target))
            }
        )
    }

    /// Wraps a terminal request in a closure for the host, or `nil` when
    /// the request is unsupported or no terminal host is wired.
    private func terminalAction(_ request: SubrouterTerminalRequest?) -> (() -> Void)? {
        guard let onOpenTerminal, let request else { return nil }
        return { onOpenTerminal(request) }
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
