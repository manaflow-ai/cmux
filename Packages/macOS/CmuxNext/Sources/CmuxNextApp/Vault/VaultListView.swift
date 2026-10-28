import CmuxNextDesign
import SwiftUI
import CmuxNextHistory

/// The vault: a search field over the session list. Rows get value snapshots
/// and an action bundle only (the snapshot boundary rule).
struct VaultListView: View {
    let vault: SessionVault
    let appearance: VaultAppearance
    let actions: VaultRowActions

    var body: some View {
        @Bindable var vault = vault
        let colors = appearance.colors
        let rows = vault.shownRows
        let selection = vault.selection
        VStack(spacing: 0) {
            HStack(spacing: Metrics.panelInset) {
                TextField(VaultStrings.searchPlaceholder, text: $vault.filter)
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()
                Button {
                    Task { await vault.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(VaultStrings.refresh)
                .disabled(vault.isLoading)
            }
            .padding(Metrics.panelInset)
            if rows.isEmpty {
                Spacer()
                Text(verbatim: vault.rows.isEmpty ? VaultStrings.empty : VaultStrings.noMatch)
                    .font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                    .multilineTextAlignment(.center).padding(Metrics.panelInset * 2)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            VaultRowView(row: row, isSelected: row.id == selection, colors: colors, actions: actions)
                        }
                    }
                    .thinScrollers()
                    .padding(.horizontal, Metrics.panelInset / 2)
                }
            }
        }
        .background(colors.background)
        .task { await vault.reload() }
    }
}
