import CmuxNextCodeRouter
public import CmuxNextDesign
public import SwiftUI

/// The onboarding step body: a plain list, one line per provider (name,
/// one status word, one button), no cards, icons or intro text (the
/// onboarding window owns the title and sentence). It shows the four
/// agent providers always and any other provider found on this Mac.
/// Failures appear as one quiet line at the end. Transparent; fills the
/// frame it is given.
public struct AccountsStepView: View {
    let model: AccountsModel
    let palette: AccountsPalette

    public init(model: AccountsModel, palette: AccountsPalette) {
        self.model = model
        self.palette = palette
    }

    static let alwaysShown: Set<AIProvider> = [.codex, .claude, .openAI, .anthropic]

    var rows: [AccountRowState] {
        model.rows.filter { Self.alwaysShown.contains($0.provider) || $0.status == .signedIn || $0.status == .expired }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.provider) { row in
                    StepRow(model: model, row: row, palette: palette)
                    if model.confirmTarget == row.provider {
                        ConnectConfirmation(model: model, provider: row.provider, palette: palette).padding(.bottom, Metrics.space3)
                    }
                    if model.pasteTarget == row.provider {
                        PasteField(model: model, provider: row.provider, palette: palette).padding(.bottom, Metrics.space3)
                    }
                }
                if let problem = lastProblem {
                    Text(problem).font(palette.caption).foregroundStyle(palette.tertiary).lineLimit(2)
                        .padding(.top, Metrics.space3)
                }
            }
            .padding(.horizontal, Metrics.space2)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .onAppear { model.refresh() }
    }

    /// The newest failure of any row.
    private var lastProblem: String? {
        for row in rows { if case .failed(let message) = row.outcome { return message } }
        return nil
    }
}

/// Name, status word, one button.
private struct StepRow: View {
    let model: AccountsModel
    let row: AccountRowState
    let palette: AccountsPalette

    var body: some View {
        HStack(spacing: Metrics.space4) {
            Text(row.provider.displayName).font(palette.body).foregroundStyle(palette.text)
            Spacer(minLength: Metrics.space4)
            Text(status).font(palette.caption).foregroundStyle(palette.secondary)
            action.frame(minWidth: 96, alignment: .trailing)
        }
        .frame(minHeight: 30)
        .accessibilityIdentifier("cmux.accounts.step.\(row.provider.rawValue)")
    }

    private var status: String {
        row.linked.isEmpty ? AccountsStrings.status(row) : AccountsStrings.connected
    }

    @ViewBuilder private var action: some View {
        if row.isBusy, row.phase != .detecting {
            ProgressView().controlSize(.mini)
        } else if !row.linked.isEmpty {
            EmptyView()
        } else if row.canConnect, row.status == .signedIn || row.connectNeedsPaste {
            Button(AccountsStrings.connectShort) { model.connect(row.provider) }
                .buttonStyle(AccountsButtonStyle(palette: palette))
                .accessibilityIdentifier("cmux.accounts.step.connect.\(row.provider.rawValue)")
        } else if row.canReauthenticate {
            Button(AccountsStrings.reauthTitle(row)) { model.reauthenticate(row.provider) }
                .buttonStyle(AccountsButtonStyle(palette: palette))
                .disabled(row.isBusy)
        }
    }
}
