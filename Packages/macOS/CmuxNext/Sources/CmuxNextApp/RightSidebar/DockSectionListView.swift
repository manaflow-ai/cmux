import CmuxNextDesign
import SwiftUI

/// The Dock section: the shown screen's docked columns; a click focuses one,
/// Undock lets it scroll again. Rows get snapshots and an action bundle only.
struct DockSectionListView: View {
    let model: DockSectionModel
    let actions: DockSectionActions

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Text(verbatim: RightSidebarStrings.dockEmpty)
                    .font(Font(Typography.caption)).foregroundStyle(.secondary)
                    .padding(Metrics.panelInset)
            }
            ForEach(rows) { row in
                HStack(spacing: Metrics.panelInset) {
                    Image(systemName: row.symbol).foregroundStyle(.secondary)
                    Text(verbatim: row.title).font(Font(Typography.body)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Metrics.panelInset)
                    Button(RightSidebarStrings.undock) { actions.undock(row.id) }.buttonStyle(.borderless)
                }
                .padding(.vertical, 3).padding(.horizontal, Metrics.panelInset)
                .contentShape(Rectangle())
                .onTapGesture { actions.focus(row.pane) }
            }
            Button(RightSidebarStrings.dockFocused) { actions.dockFocused() }
                .buttonStyle(.borderless).padding(Metrics.panelInset)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
