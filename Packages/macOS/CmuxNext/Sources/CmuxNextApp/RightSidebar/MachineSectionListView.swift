import CmuxNextDesign
import SwiftUI

/// The Cloud section: every machine with its link state; New Workspace opens
/// a workspace on it (`workspace.newOnMachine`).
struct MachineSectionListView: View {
    let model: MachineSectionModel
    let newWorkspace: @MainActor (String) -> Void

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: Metrics.panelInset) {
                    Image(systemName: row.isLocal ? "laptopcomputer" : "cloud").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.name).font(Font(Typography.body)).lineLimit(1)
                        Text(verbatim: row.isConnected ? RightSidebarStrings.connected : RightSidebarStrings.offline)
                            .font(Font(Typography.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Metrics.panelInset)
                    Button {
                        newWorkspace(row.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help(RightSidebarStrings.newWorkspace)
                    .disabled(!row.isConnected)
                }
                .padding(.vertical, 3).padding(.horizontal, Metrics.panelInset)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
