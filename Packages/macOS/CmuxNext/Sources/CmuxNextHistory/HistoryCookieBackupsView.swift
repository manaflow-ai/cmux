import CmuxNextDesign
import SwiftUI

/// The History page's cookie backups sheet (decision D3, issue 13742): the
/// sites whose cookies an agent cleared, with the encrypted copy cmux keeps
/// so the agent can undo the clear. Only the person deletes a copy, after a
/// confirmation.
struct HistoryCookieBackupsView: View {
    @Bindable var model: HistoryPageModel
    let colors: HistoryPageColors
    @State private var pendingDelete: [String] = []
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.panelInset * 1.5) {
            Text(HistoryStrings.cookieBackupsTitle).font(Font(Typography.title)).foregroundStyle(colors.primary)
            Text(HistoryStrings.cookieBackupsExplanation)
                .font(Font(Typography.body)).foregroundStyle(colors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.cookieBackups.isEmpty {
                Text(HistoryStrings.cookieBackupsEmpty)
                    .font(Font(Typography.body)).foregroundStyle(colors.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(model.cookieBackups) { backup in
                    HStack(spacing: Metrics.panelInset) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.site ?? HistoryStrings.cookieBackupsUnreadable)
                                .font(Font(Typography.bodyEmphasized))
                                .foregroundStyle(backup.site == nil ? colors.secondary : colors.primary)
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Font(Typography.body)).foregroundStyle(colors.tertiary)
                        }
                        Spacer(minLength: 0)
                        Button(HistoryStrings.cookieBackupsDelete) { ask([backup.id]) }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).frame(minHeight: 160)
            }
            HStack {
                Button(HistoryStrings.cookieBackupsDeleteAll, role: .destructive) { ask(model.cookieBackups.map(\.id)) }
                    .disabled(model.cookieBackups.isEmpty)
                Spacer()
                Button(HistoryStrings.cookieBackupsDone) { model.showsCookieBackups = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.panelInset * 3)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        .background(colors.background)
        .confirmationDialog(HistoryStrings.cookieBackupsConfirmTitle, isPresented: $confirming) {
            Button(HistoryStrings.cookieBackupsConfirmDelete, role: .destructive) { model.deleteCookieBackups(pendingDelete) }
        } message: {
            Text(HistoryStrings.cookieBackupsConfirmMessage)
        }
    }

    private func ask(_ ids: [String]) {
        pendingDelete = ids
        confirming = !ids.isEmpty
    }
}
