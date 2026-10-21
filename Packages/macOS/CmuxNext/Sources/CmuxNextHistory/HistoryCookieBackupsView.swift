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
                    .thinScrollers()
                }
                .listStyle(.plain).scrollContentBackground(.hidden).frame(minHeight: 160)
            }
            if confirming {
                // The delete question in place of the actions (u2647: a system confirmation
                // dialog cannot show its keys): Escape keeps the copies, Return deletes them.
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Text(HistoryStrings.cookieBackupsConfirmTitle).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                    Text(HistoryStrings.cookieBackupsConfirmMessage).font(Font(Typography.body)).foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        CmuxDialogActionButton(CmuxDialogStrings.cancel, hint: .escape) { confirming = false }
                        CmuxDialogActionButton(HistoryStrings.cookieBackupsConfirmDelete, hint: .return, role: .destructive) {
                            confirming = false
                            model.deleteCookieBackups(pendingDelete)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cmux.history.cookieBackups.confirm")
            } else {
                HStack {
                    Button(HistoryStrings.cookieBackupsDeleteAll, role: .destructive) { ask(model.cookieBackups.map(\.id)) }
                        .disabled(model.cookieBackups.isEmpty)
                    Spacer()
                    CmuxDialogActionButton(HistoryStrings.cookieBackupsDone, hint: .return) { model.showsCookieBackups = false }
                }
            }
        }
        .padding(Metrics.panelInset * 3)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320)
        .background(colors.background)
        // The default button in the theme's selection fill, never the system blue (cx-wqn5).
        .tint(colors.selection)
    }

    private func ask(_ ids: [String]) {
        pendingDelete = ids
        confirming = !ids.isEmpty
    }
}
