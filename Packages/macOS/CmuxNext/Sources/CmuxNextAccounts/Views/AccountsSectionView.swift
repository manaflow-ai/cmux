import CmuxNextCodeRouter
public import CmuxNextDesign
public import SwiftUI

/// Settings > Accounts: the intro, the cmux sign-in banner, then one card
/// per provider group. Refreshes when it appears.
public struct AccountsSectionView: View {
    let model: AccountsModel
    let palette: AccountsPalette

    public init(model: AccountsModel, palette: AccountsPalette) {
        self.model = model
        self.palette = palette
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space6) {
            AccountsHeader(model: model, palette: palette)
            ForEach(AIProvider.Group.allCases, id: \.self) { group in
                let rows = model.rows(in: group)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.space2) {
                        Text(AccountsStrings.group(group)).font(palette.header).foregroundStyle(palette.secondary)
                            .padding(.leading, Metrics.space2)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.provider) { index, row in
                                if index > 0 { Rectangle().fill(palette.separator).frame(height: 1).padding(.leading, Metrics.space5) }
                                AccountRowView(model: model, row: row, palette: palette)
                            }
                        }
                        .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
                    }
                }
            }
        }
        .onAppear { model.refresh() }
    }
}

/// Intro line, refresh, and the cmux sign-in banner when signed out.
private struct AccountsHeader: View {
    let model: AccountsModel
    let palette: AccountsPalette

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountsStrings.intro).font(palette.caption).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.space4)
                if model.isRefreshing { ProgressView().controlSize(.mini) }
                Button(AccountsStrings.refresh) { model.refresh() }
                    .buttonStyle(AccountsButtonStyle(palette: palette))
                    .disabled(model.isRefreshing)
                    .accessibilityIdentifier("cmux.accounts.refresh")
            }
            if !model.isSignedInToCmux {
                HStack(spacing: Metrics.space4) {
                    Text(AccountsStrings.cmuxSignedOut).font(palette.caption).foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.space4)
                    Button(AccountsStrings.signInToCmux) { model.services.signInToCmux() }
                        .buttonStyle(AccountsButtonStyle(palette: palette))
                        .accessibilityIdentifier("cmux.accounts.signInCmux")
                }
                .padding(Metrics.space4)
                .background(palette.hover, in: RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous))
            } else if let problem = model.codeRouterProblem {
                Text(AccountsStrings.codeRouterUnavailable(problem)).font(palette.caption).foregroundStyle(palette.attention)
            }
        }
    }
}
