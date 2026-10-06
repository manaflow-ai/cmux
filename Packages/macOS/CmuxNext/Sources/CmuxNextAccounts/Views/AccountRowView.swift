import CmuxAgentBrands
import CmuxNextCodeRouter
import CmuxNextDesign
import SwiftUI

/// One provider: name, status, redacted account label and source, the
/// buttons its state allows, CodeRouter's linked accounts, and the inline
/// paste field when it is the paste target.
struct AccountRowView: View {
    let model: AccountsModel
    let row: AccountRowState
    let palette: AccountsPalette

    /// The provider's brand mark (design/agent-icons), or its symbol when it has none.
    @ViewBuilder private var providerIcon: some View {
        if AgentBrandCatalog.brand(for: row.provider.rawValue) != nil {
            AgentBrandMark(agent: row.provider.rawValue, size: Metrics.iconSize, style: .brand)
        } else {
            Image(systemName: row.provider.symbol)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space4) {
                providerIcon
                    .foregroundStyle(palette.secondary).frame(width: Metrics.iconSize + Metrics.space2)
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text(row.provider.displayName).font(palette.emphasized).foregroundStyle(palette.text)
                    if let detail { Text(detail).font(palette.caption).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: Metrics.space4)
                HStack(spacing: Metrics.space2) {
                    if row.isBusy, row.phase != .detecting { ProgressView().controlSize(.mini) }
                    Circle().fill(palette.statusColor(row)).frame(width: 6, height: 6)
                    Text(AccountsStrings.status(row)).font(palette.caption).foregroundStyle(palette.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cmux.accounts.status.\(row.provider.rawValue)")
            }
            buttons.padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            ForEach(row.linked) { account in
                LinkedAccountLine(account: account, busy: row.phase == .removing(accountID: account.id), palette: palette) {
                    model.remove(account)
                }
                .padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            }
            if row.provider.codeRouterLink == .bedrockKeys, model.isSignedInToCmux, !row.hasBedrockKeys {
                Text(AccountsStrings.bedrockNeedsKeys).font(palette.caption).foregroundStyle(palette.tertiary)
                    .padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            }
            if let outcome { outcome.padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4) }
            if model.confirmTarget == row.provider {
                ConnectConfirmation(model: model, provider: row.provider, palette: palette)
                    .padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            }
            if model.pasteTarget == row.provider {
                PasteField(model: model, provider: row.provider, palette: palette)
                    .padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            }
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space3)
        .accessibilityIdentifier("cmux.accounts.row.\(row.provider.rawValue)")
    }

    /// A redacted account label, never an email or a secret (shared with the Settings page).
    private var detail: String? { AccountsModel.detail(row) }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: Metrics.space3) {
            if row.canReauthenticate {
                Button(reauthTitle) { model.reauthenticate(row.provider) }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.reauth.\(row.provider.rawValue)")
            }
            if row.provider.acceptsPastedKey {
                Button(AccountsStrings.addKey) { model.pasteTarget = row.provider }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.addKey.\(row.provider.rawValue)")
                if row.detection?.sources.contains(.cmuxKeychain) == true {
                    Button(AccountsStrings.deleteSavedKey) { model.deleteSavedKey(for: row.provider) }
                }
            }
            // Shown only when it can run (signed in to cmux, CodeRouter
            // reachable, a routable provider); no line says why not.
            if row.canConnect || row.phase == .connecting {
                Button(AccountsStrings.connect) { model.connect(row.provider) }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.connect.\(row.provider.rawValue)")
            }
        }
        .buttonStyle(AccountsButtonStyle(palette: palette))
    }

    private var reauthTitle: String { AccountsStrings.reauthTitle(row) }

    private var outcome: Text? {
        switch row.outcome {
        case .connected: Text(AccountsStrings.connected).font(palette.caption).foregroundStyle(palette.success)
        case .removed: Text(AccountsStrings.removed).font(palette.caption).foregroundStyle(palette.secondary)
        case .failed(let message): Text(message).font(palette.caption).foregroundStyle(palette.danger)
        case nil: nil
        }
    }
}

/// One account CodeRouter holds: label, state, Remove.
private struct LinkedAccountLine: View {
    let account: LinkedAccount
    let busy: Bool
    let palette: AccountsPalette
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.space3) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(palette.tertiary)
            Text(account.label).font(palette.caption).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
            Text(account.state).font(palette.caption).foregroundStyle(account.isHealthy ? palette.secondary : palette.attention)
            Spacer(minLength: Metrics.space4)
            Button(AccountsStrings.remove, action: remove)
                .buttonStyle(AccountsButtonStyle(palette: palette, destructive: true))
                .disabled(busy)
                .accessibilityIdentifier("cmux.accounts.remove.\(account.id)")
        }
    }
}

/// Connect confirmation with the Codex refresh-token note.
struct ConnectConfirmation: View {
    let model: AccountsModel
    let provider: AIProvider
    let palette: AccountsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text(AccountsStrings.codexRefreshNote).font(palette.caption).foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Metrics.space3) {
                Button(AccountsStrings.confirmConnect) { model.connect(provider, confirmed: true) }
                    .accessibilityIdentifier("cmux.accounts.confirm.\(provider.rawValue)")
                Button(AccountsStrings.cancel) { model.confirmTarget = nil }
            }
            .buttonStyle(AccountsButtonStyle(palette: palette))
        }
        .padding(Metrics.space4)
        .background(palette.hover, in: RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous))
    }
}
