import CmuxAgentBrands
import CmuxNextDesign
import SwiftUI
import CmuxNextHistory

/// One session of the vault list: the agent's mark, title, folder and last activity.
struct VaultRowView: View {
    let row: VaultRow
    let isSelected: Bool
    let colors: VaultColors
    let actions: VaultRowActions

    var body: some View {
        HStack(spacing: Metrics.panelInset) {
            AgentBrandMark(agent: row.session.provider, size: Metrics.iconSize)
                .foregroundStyle(colors.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title).font(Font(Typography.body)).foregroundStyle(colors.primary)
                    .lineLimit(1).truncationMode(.tail)
                if let detail = row.detail {
                    Text(verbatim: detail).font(Font(Typography.caption)).foregroundStyle(colors.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Metrics.panelInset)
            if row.isLive {
                Circle().fill(colors.live).frame(width: 6, height: 6).themedHelp(VaultStrings.running)
            }
            Text(row.session.lastActivityAt, style: .relative)
                .font(Font(Typography.caption)).foregroundStyle(colors.tertiary).monospacedDigit().lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Metrics.panelInset)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? colors.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.perform("vaultOpenSession", row.id) }
        .onTapGesture { actions.select(row.id) }
        .contextMenu { menu }
        .themedHelp(row.session.cwd ?? row.title)
    }

    @ViewBuilder private var menu: some View {
        if row.isLive {
            Button(VaultStrings.focusSession) { actions.perform("vaultFocusSession", row.id) }
        }
        Button(VaultStrings.openSession) { actions.perform("vaultOpenSession", row.id) }.disabled(!row.canResume)
        Button(VaultStrings.resumeInNewWorkspace) { actions.perform("vaultResumeInNewWorkspace", row.id) }.disabled(!row.canResume)
        Divider()
        Button(VaultStrings.copyResumeCommand) { actions.perform("vaultCopyResumeCommand", row.id) }.disabled(!row.canResume)
        Button(VaultStrings.openPullRequest) { actions.perform("vaultOpenPullRequest", row.id) }
    }
}
