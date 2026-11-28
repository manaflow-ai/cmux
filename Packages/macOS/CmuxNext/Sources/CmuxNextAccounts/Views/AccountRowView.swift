import CmuxAgentBrands
import CmuxNextCodeRouter
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// One provider: name, status, redacted account label and source, the
/// buttons its state allows, and the inline paste field when it is the
/// paste target.
struct AccountRowView: View {
    let model: AccountsModel
    let row: AccountRowState
    let palette: AccountsPalette

    /// The provider's brand mark (design/agent-icons), or its symbol when it has none.
    @ViewBuilder private var providerIcon: some View {
        if AgentBrandCatalog.brand(for: row.provider.rawValue) != nil {
            AgentBrandMark(agent: row.provider == .codex ? "chatgpt" : row.provider.rawValue, size: Metrics.iconSize, style: .brand)
                .environment(\.colorScheme, palette.isDark ? .dark : .light)
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
                    if row.isBusy, row.phase != .detecting { ThemedSpinner(size: 10) }
                    Circle().fill(palette.statusColor(row)).frame(width: 6, height: 6)
                    Text(AccountsStrings.status(row)).font(palette.caption).foregroundStyle(palette.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("cmux.accounts.status.\(row.provider.rawValue)")
            }
            buttons.padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4)
            if let outcome { outcome.padding(.leading, Metrics.iconSize + Metrics.space2 + Metrics.space4) }
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
                Button(reauthTitle) { Task { await model.reauthenticate(row.provider) } }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.reauth.\(row.provider.rawValue)")
            }
            if row.canSignOut {
                Button(AccountsStrings.signOut, role: .destructive) { Task { await model.signOut(row.provider) } }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.signOut.\(row.provider.rawValue)")
            }
            if row.provider.acceptsPastedKey {
                Button(AccountsStrings.addKey) { model.pasteTarget = row.provider }
                    .disabled(row.isBusy)
                    .accessibilityIdentifier("cmux.accounts.addKey.\(row.provider.rawValue)")
                if row.detection?.sources.contains(.cmuxKeychain) == true {
                    Button(AccountsStrings.deleteSavedKey) { model.deleteSavedKey(for: row.provider) }
                }
            }
        }
        .buttonStyle(AccountsButtonStyle(palette: palette))
    }

    private var reauthTitle: String { AccountsStrings.reauthTitle(row) }

    private var outcome: Text? {
        switch row.outcome {
        case .failed(let message): Text(message).font(palette.caption).foregroundStyle(palette.danger)
        case nil: nil
        }
    }
}
