import SwiftUI

struct WorkspaceTasksHeaderView: View {
    let openCount: Int
    let archivedCount: Int
    let showsOpenAsTabButton: Bool
    let openSurface: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .cmuxSymbolRasterSize(16)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "workspaceTasks.surface.title", defaultValue: "Workspace Tasks"))
                    .cmuxFont(size: 14, weight: .semibold)
                Text(summary)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsOpenAsTabButton {
                Button(action: openSurface) {
                    Image(systemName: "macwindow.badge.plus")
                        .cmuxSymbolRasterSize(14)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help(String(localized: "workspaceTasks.openAsTab.help", defaultValue: "Open as tab"))
                .accessibilityLabel(String(localized: "workspaceTasks.openAsTab.label", defaultValue: "Open Workspace Tasks as Tab"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        String(
            format: String(localized: "workspaceTasks.summary", defaultValue: "%d open, %d archived"),
            locale: .current,
            openCount,
            archivedCount
        )
    }
}
